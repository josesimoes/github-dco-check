# Copyright (c) .NET Foundation and Contributors
# See LICENSE file in the project root for full license information.

# This PS update the .NET nanoFramework dependencies on the repo where it's running

# optional parameters:
# nugetReleaseType:  to request for stable or preview releases to be used when updating NuGets
# targetSolutions: solution (or solutions) to update
param (
    [string]$nugetReleaseType,
    [string]$targetPath,
    [string]$targetSolutions
    )

if ([string]::IsNullOrEmpty($nugetReleaseType))
{
    if($env:GITHUB_REF -like '*release*' -or $env:GITHUB_REF -like '*master*' -or $env:GITHUB_REF -like '*main*' -or $env:GITHUB_REF -like '*stable*')
    {
        $nugetReleaseType = "stable"
    }
    else
    {
        $nugetReleaseType = "prerelease"
    }
}
else
{
    if($nugetReleaseType -ne 'stable' -and $nugetReleaseType -ne 'prerelease' )
    {
        $nugetReleaseType = "stable"
    }
}

# check if this is running in Azure Pipelines or GitHub actions
if($env:NF_Library -ne $null)
{
    ######################################
    # this is building from Azure Pipelines

    Set-Location "$env:Build_SourcesDirectory\$env:NF_Library" | Out-Null

    $library = $env:NF_Library
}
elseif($env:GITHUB_ACTIONS)
{
    ######################################
    # this is building from github actions

    # get repository name from the repo path
    Set-Location ".." | Out-Null
    $library = Split-Path $(Get-Location) -Leaf

    "Repository: '$library'" | Write-Host

    # need this to move to the 
    "Moving to 'main' folder" | Write-Host

    Set-Location "main" | Out-Null
}

# set working path
if ([string]::IsNullOrEmpty($targetPath))
{
    $workingPath = $(Get-Location)
}
else
{
    $workingPath = "$targetPath"
}

Write-Host "Working path is: $workingPath"

# init/reset these
$updateCount = 0
$commitMessage = ""
$prTitle = ""
$newBranchName = "nfbot/update-dependencies/" + [guid]::NewGuid().ToString()

# need this to remove definition of redirect stdErr (only on Azure Pipelines image fo VS2019)
$env:GIT_REDIRECT_STDERR = '2>&1'

# setup github stuff
git config --global gc.auto 0
git config --global user.name nfbot
git config --global user.email dependencybot@nanoframework.net
git config --global core.autocrlf true

# temporarily rename csproj files to projcs-temp so they are not affected.
Get-ChildItem -Path $workingPath -Include "*.csproj" -Recurse |
    Foreach-object {
        $OldName = $_.name; 
        $NewName = $_.name -replace '.csproj','.projcs-temp'; 
        Rename-Item  -Path $_.fullname -Newname $NewName; 
    }

# temporarily rename nfproj files to csproj
Get-ChildItem -Path $workingPath -Include "*.nfproj" -Recurse |
    Foreach-object {
        $OldName = $_.name; 
        $NewName = $_.name -replace '.nfproj','.csproj'; 
        Rename-Item  -Path $_.fullname -Newname $NewName; 
    }

if ([string]::IsNullOrEmpty($targetSolutions))
{
    Write-Host "Targeting every solution in the repository."

    # set Include to all sln files
    $targetSolutions = "*.sln"
}
else
{
    Write-Host "Targeting only this(ese) solution(s): '$targetSolutions'."
}

# find every solution file in repository
$solutionFiles = (Get-ChildItem -Path "$workingPath" -Include "$targetSolutions"  -Recurse)

# loop through solution files and replace content containing:
# 1) .csproj to .projcs-temp (to prevent NuGet from touching these)
# 2) and .nfproj to .csproj so nuget can handle them
foreach ($solutionFile in $solutionFiles)
{
    $content = Get-Content $solutionFile -Encoding utf8
    $content = $content -replace '.csproj', '.projcs-temp'
    $content = $content -replace '.nfproj', '.csproj'
    $content | Set-Content -Path $solutionFile -Encoding utf8 -Force
}
    
# find NuGet.Config
$nugetConfig = (Get-ChildItem -Path "$workingPath" -Include "NuGet.Config" -Recurse) | Select-Object -First 1

foreach ($solutionFile in $solutionFiles)
{
    # check if there are any csproj here
    $slnFileContent = Get-Content $solutionFile -Encoding utf8
    $hascsproj = $slnFileContent | Where-Object {$_ -like '*.csproj*'}
    if($hascsproj -eq $null)
    {
        continue
    }

    $solutionPath = Split-Path -Path $solutionFile

    if (![string]::IsNullOrEmpty($nugetConfig))
    {
        nuget restore $solutionFile -ConfigFile $nugetConfig
    }
    else
    {
        nuget restore $solutionFile
    }

    # find ALL packages.config files in the solution projects
    $packagesConfigs = (Get-ChildItem -Path "$solutionPath" -Include "packages.config" -Recurse)

    foreach ($packagesConfig in $packagesConfigs)
    {
        # check if this project is in our solution file
        $pathOfProject = Split-Path -Path $packagesConfig -Parent
        $projectPathInSln = $pathOfProject.Replace("$solutionPath\",'')

        $isProjecInSolution = $slnFileContent | Where-Object {$_.ToString().Contains($projectPathInSln)}
        if($isProjecInSolution -eq $null)
        {
            continue
        }

        # get project(s) at path
        $projectsAtPath = Get-ChildItem -Path $pathOfProject -Include '*.csproj' -Recurse

        foreach ($projectToUpdate in $projectsAtPath)
        {
            "Updating $projectToUpdate.FullName" | Write-Host

            # load packages.config as XML doc
            [xml]$packagesDoc = Get-Content $packagesConfig -Encoding utf8

            $nodes = $packagesDoc.SelectNodes("*").SelectNodes("*")

            $packageList = @(,@())

            "Building package list to update" | Write-Host

            foreach ($node in $nodes)
            {
                # filter out Nerdbank.GitVersioning package
                if($node.id -notlike "Nerdbank.GitVersioning*")
                {
                    "Adding {0} {1}" -f [string]$node.id,[string]$node.version | Write-Host
                    if($packageList)
                    {
                        $packageList += , ($node.id,  $node.version)
                    }
                    else
                    {
                        $packageList = , ($node.id,  $node.version)
                    }
                }
            }

            if ($packageList.length -gt 0)
            {
                "NuGet packages to update:" | Write-Host
                $packageList | Write-Host
                
                # update all packages
                foreach ($package in $packageList)
                {
                    # get package name and target version
                    [string]$packageName = $package[0]
                    [string]$packageOriginVersion = $package[1]

                    "Updating package $packageName from $packageOriginVersion" | Write-Host

                    if ($nugetReleaseType -like '*stable*')
                    {
                        # don't allow prerelease for release and master branches

                        if (![string]::IsNullOrEmpty($nugetConfig))
                        {
                            nuget update $projectToUpdate.FullName -Id "$packageName" -ConfigFile $nugetConfig -FileConflictAction Overwrite
                        }
                        else
                        {
                            nuget update $projectToUpdate.FullName -Id "$packageName" -FileConflictAction Overwrite
                        }

                    }
                    else
                    {

                        if (![string]::IsNullOrEmpty($nugetConfig))
                        {
                            nuget update $projectToUpdate.FullName -Id "$packageName" -ConfigFile $nugetConfig -PreRelease -FileConflictAction Overwrite
                        }
                        else
                        {
                            nuget update $projectToUpdate.FullName -Id "$packageName" -PreRelease -FileConflictAction Overwrite
                        }
                    }

                    # need to get target version
                    # load packages.config as XML doc
                    [xml]$packagesDoc = Get-Content $packagesConfig -Encoding utf8

                    $nodes = $packagesDoc.SelectNodes("*").SelectNodes("*")

                    foreach ($node in $nodes)
                    {
                        # find this package
                        if($node.id -eq $packageName)
                        {
                            $packageTargetVersion = $node.version

                            # done here
                            break
                        }
                    }

                    # sanity check
                    if($packageTargetVersion -eq $packageOriginVersion)
                    {
                        "Skip update of $packageName because it has the same version as before: $packageOriginVersion." | Write-Host -ForegroundColor Cyan
                    }
                    elseif ($packageTargetVersion.Contains('alpha'))
                    {
                        "Skip update of $packageName because it's trying to use an alpha version!" | Write-Host -ForegroundColor Red

                        # done here
                        return
                    }
                    else
                    {
                        # if we are updating samples repo, OK to move to next one
                        if($Env:GITHUB_REPOSITORY -eq "nanoframework/Samples")
                        {
                            $updateCount = $updateCount + 1;
                            
                            # build commit message
                            $commitMessage += "Bumps $packageName from $packageOriginVersion to $packageTargetVersion</br>"

                            # done here
                            continue
                        }

                        "Bumping $packageName from $packageOriginVersion to $packageTargetVersion." | Write-Host -ForegroundColor Cyan                

                        "Updating NFMDP_PE LoadHints" | Write-Host

                        # replace NFMDP_PE_LoadHints
                        $filecontent = Get-Content $projectToUpdate.FullName -Encoding utf8
                        attrib $project -r
                        $filecontent -replace "($packageName.$packageOriginVersion)", "$packageName.$packageTargetVersion" | Out-File $projectToUpdate.FullName -Encoding utf8 -Force

                        # update nuspec files, if any
                        $nuspecFiles = (Get-ChildItem -Path "$solutionPath" -Include "*.nuspec" -Recurse)
                        
                        if ($nuspecFiles.length -gt 0)
                        {
                            "Updating nuspec files" | Write-Host

                            foreach ($nuspec in $nuspecFiles)
                            {
                                "Trying update on nuspec file: '$nuspec.FullName' " | Write-Host

                                [xml]$nuspecDoc = Get-Content $nuspec -Encoding UTF8

                                $nodes = $nuspecDoc.SelectNodes("*").SelectNodes("*")

                                foreach ($node in $nodes)
                                {
                                    if($node.Name -eq "metadata")
                                    {
                                        foreach ($metadataItem in $node.ChildNodes)
                                        {                          
                                            if($metadataItem.Name -eq "dependencies")
                                            {
                                                foreach ($dependency in $metadataItem.ChildNodes)
                                                {
                                                    if($dependency.Attributes["id"].value -eq $packageName)
                                                    {
                                                        "Updating dependency: $packageName to $packageTargetVersion" | Write-Host
                                                        $dependency.Attributes["version"].value = "$packageTargetVersion"
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                $nuspecDoc.Save($nuspec[0].FullName)
                            }

                            "Finished updating nuspec files." | Write-Host
                        }
                        else
                        {
                            "No nuspec files to update." | Write-Host
                        }

                        # build commit message
                        $updateMessage = "Bumps $packageName from $packageOriginVersion to $packageTargetVersion</br>";

                        if($commitMessage.Contains($updateMessage))
                        {
                            # already reported
                        }
                        else
                        {
                            # update message
                            $commitMessage += $updateMessage

                            # update count
                            $updateCount = $updateCount + 1;
                        }
                    }
                }
            }
        }
    }
}

# rename csproj files back to nfproj
Get-ChildItem -Path $workingPath -Include "*.csproj" -Recurse |
Foreach-object {
    $NewName = $_.name -replace '.csproj','.nfproj'; 
    Rename-Item  -Path $_.fullname -Newname $NewName; 
    }

# rename projcs-temp files back to csproj
Get-ChildItem -Path $workingPath -Include "*.projcs-temp" -Recurse |
Foreach-object {
    $NewName = $_.name -replace '.projcs-temp','.csproj'; 
    Rename-Item  -Path $_.fullname -Newname $NewName; 
    }

# loop through solution files and revert names to default.
foreach ($solutionFile in $solutionFiles)
{
    $content = Get-Content $solutionFile -Encoding utf8
    $content = $content -replace '.csproj', '.nfproj'
    $content = $content -replace '.projcs-temp', '.csproj'
    $content | Set-Content -Path $solutionFile -Encoding utf8 -Force
}

# Potential workkaround for whitespace only changes?
#git diff -U0 -w --no-color | git apply --cached --ignore-whitespace --unidiff-zero -
#git checkout .

if($updateCount -eq 0)
{
    # something went wrong as no package was updated and it should be at least one
    'No packages were updated...' | Write-Host -ForegroundColor Yellow
}
else
{
    "Number of packages updated: $updateCount" | Write-Host
    "Generating PR information..." | Write-Host
   
    # fix PR title
    $prTitle = "Update $updateCount nuget dependencies"

    echo "CREATE_PR=true" | Out-File -FilePath $Env:GITHUB_ENV -Encoding utf8 -Append
    echo "BRANCH_NAME=$newBranchName" | Out-File -FilePath $Env:GITHUB_ENV -Encoding utf8 -Append
    echo "PR_MESSAGE=$commitMessage" | Out-File -FilePath $Env:GITHUB_ENV -Encoding utf8 -Append
    echo "PR_TITLE=$prTitle" | Out-File -FilePath $Env:GITHUB_ENV -Encoding utf8 -Append   
}
