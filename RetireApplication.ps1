<#
#=======================================================================================
# Name: RetireApplication.ps1
# Version: 2.2
# Jon Carracino
# Comment: This script will retire a selected application only. Packages are handeled in seperate script!
Updates:
  1.3 - fixed multiple issues with possible source paths, content copy error handling
  2.0 - updated for Azure compatibility and support of multiple site locations. 
  2.1 - Changed source server paths to reflect changes necessary for rehyration work.  
  2.2 - Updated DT detection and method to change content location based on changes to 1910 Mem-CM. 
# 
# Usage:
#	powershell.exe -ExecutionPolicy Bypass .\RetireApplication.ps1 [Parameters]
#   
# Parameters: Had to look this up - packages\apps dont always use primary server for namespace..
#		 sdkserver - netbios format
#		 sitenamespae - root\site\site_ format
#		 modelname - given GUID from right click context
#=======================================================================================
#>

#Set - Variables:
$sdkserver = $args[0]
$SiteNamespace = $args[1]
$SiteCode = $SiteNamespace.SubString($SiteNamespace.Indexof("site_") +5)
$modelname = $args[2]
$Scope = "Retired"
$NewRootPath = "\\server\folderlocation\retiredApps"
$LogPath = '\\server\folder\RetiredApplications.log'
 # Format Date for our Log File 
$FormattedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss" 

## Start entry in Log File:
add-content $LogPath "#########################################################"
add-content $LogPath "$FormattedDate : App Retirement invoked by $env:username - AppID:$modelname"


try
{
	if ($NewRootPath.substring($NewRootPath.length-1) -ne '\') { $NewRootPath+= '\' }
	"{0} {1} {2} {3} {4} {5}" -f $sdkserver, $SiteNamespace, $SiteCode, $modelname, $Scope, $NewRootPath

	if ((Read-Host "Are you really sure you want to retire the application? (Y/N)").Tolower() -eq "n")
	{
		Write-Host "Cancelled by the user, no action taken..." -ForegroundColor Red
        add-content $LogPath "Action Canceled by User"
		exit
	}

	$AppList = gwmi -computername "$sdkserver" -Namespace "Root\SMS\Site_$SiteCode" -class SMS_ApplicationLatest -filter "ModelName = '$modelname'"
	if ($AppList -eq $null)
	{
		Write-Host "Invalid ModelName ($ModelName)" -ForegroundColor yellow
        add-content $LogPath "Invalid ModelName ($ModelName) ... Action Canceled."
		exit
	}
	else
	{
	}

	Write-host "Querying Current Folder information"
	$currentcontainerInfo = gwmi -computername "$sdkserver" -Namespace "root\sms\site_$SiteCode" -query "SELECT distinct ci.ContainerNodeID FROM SMS_ApplicationLatest app, SMS_ObjectContainerItem ci WHERE app.ModelName = ci.InstanceKey and app.IsHidden=0 and app.ModelName = '$modelname'"
	if ($currentcontainerInfo -eq $null)
	{
		Write-Host "Invalid Folder for application ($modelname)" -ForegroundColor yellow
		exit
	}

	
    Write-host "Querying $Scope Folder information"
	$folderInfo = gwmi -computername "$sdkserver" -Namespace "Root\SMS\Site_$SiteCode" -query "SELECT distinct ContainerNodeID FROM SMS_ObjectContainerNode where ObjectTypeName = 'sms_applicationLatest' and Name = '$Scope'"
	if ($folderInfo -eq $null)
	{
		Write-Host "Invalid Folder ($Scope)" -ForegroundColor yellow
		exit
	} 

    <#  -Possible Scope details to be used in future if DMT makes more than just default?
	Write-Host "Querying Security Scope information..."
	$SecurityScope = gwmi -computername "$sdkserver" -Namespace "root\sms\site_$SiteCode" -query "SELECT * FROM SMS_SecuredCategory where CategoryName = '$Scope'"
	if ($SecurityScope -eq $null)
	{
		Write-Host "Invalid Security Scope ($Scope)" -ForegroundColor yellow
		exit
	}
    #>


	Write-Host "Importing CM12 powershell module..."
	import-module $env:SMS_ADMIN_UI_PATH.Replace("bin\i386","bin\ConfigurationManager.psd1") -force

#	if ((get-psdrive $SiteCode -erroraction SilentlyContinue | measure).Count -ne 1)
#	{
#		new-psdrive -Name $SiteCode -PSProvider "AdminUI.PS.Provider\CMSite" -Root $sdkserver
#	}
    #ensure correct PSDrive for site exists: had to remove current PSdrive as it could have old connection reference
    Remove-PSDrive $SiteCode -force
    new-psdrive -Name $SiteCode -PSProvider "AdminUI.PS.Provider\CMSite" -Root $sdkserver
	cd "$($SiteCode):"

	foreach ($App in $AppList) 
	{
		$CurrentAppName = $App.LocalizedDisplayName
		$NewName = "Retired-$($CurrentAppName)"
        
        Write-host "Renaming Application $CurrentAppName to $NewName" 
        $Log1 = "Renaming Application $CurrentAppName to $NewName"
		##Renaming app to Retired-
		Set-CMApplication -Name $CurrentAppName -NewName $NewName

		##Move Application to Retired folder
		Write-host "Moving Application to Folder $Scope"
		#Invoke-WmiMethod -computername "$sdkserver" -Namespace "Root\SMS\Site_$SiteCode" -Class SMS_objectContainerItem -Name MoveMembers -ArgumentList $currentcontainerInfo.ContainerNodeID,$modelname,6000,$FolderInfo.ContainerNodeID | out-null
        Get-CMApplication -Name $NewName | Move-CMObject -FolderPath "C1A:\Application\Desktop\Retired"	

		##Get all Deployments
		Write-host "Querying Deployment information"
		$DeploymentList = Get-CMDeployment | where {$_.ModelName -eq $modelname}
		foreach ($Deployment in $DeploymentList)
		{
			Write-host "Removing Deployment: $($Deployment.SoftwareName)"
            $Logtemp = "Removing Deployment: $($Deployment.SoftwareName)"
            $Colltemp = "Collection Review: $($Deployment.CollectionName):$($Deployment.CollectionID)"
            $CollLog = $Colltemp + "; " + $CollLog
            $Log2 =  $Logtemp + "; " + $Log2
			Remove-CMDeployment -DeploymentId $Deployment.DeploymentID -ApplicationName $NewName -Force
		}

		##Get All Deployment Type
		Write-host "Querying Deployment Type Information"
        $i = 0
		$DTList = Get-CMDeploymentType -ApplicationName $NewName
        $CMApplication = Get-CMApplication -Name $NewName
		foreach ($DT in $DTList)
		{
			Write-host "Getting source location information"
            #check if xml entry is invalid
			if (($CMApplication.SDMPackageXML -eq $null) -or ($CMApplication.SDMPackageXML.trim() -eq ""))
			{
				Write-host "Unable to determine the current source location. ignoring moving content to retired folder" -ForegroundColor yellow
                $LogErrorCode = "Error in Application XML - Not valid and no source info!"
			}
			else
			{
				##get source folder and copy files to retired folder
				#$xml = [xml]$dt.SDMPackageXML  - this was old way that had issue with 1606

                #new way - need to deserialize xml
                $xml = [Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer]::DeserializeFromString($CMApplication.SDMPackageXML)

                $AppLocation = $xml.DeploymentTypes[$i].Installer.Contents.Location
				#$AppLocation = $xml.AppMgmtDigest.DeploymentType.Installer.Contents.Content.Location		
                
				if ($AppLocation.substring($AppLocation.length-1) -eq '\') { $AppLocation = $AppLocation.Substring(0, $AppLocation.Length-1) }
				$newSourcePath = "$($NewRootPath)$($CurrentAppName)_$($AppLocation.Substring($AppLocation.LastIndexOf("\")+1))\$($AppLocation.Substring($AppLocation.LastIndexOf("\")+1))"
	            $newPath = "$($NewRootPath)$($CurrentAppName)_$($AppLocation.Substring($AppLocation.LastIndexOf("\")+1))"
				
                $Log3 = "Previous source path: $AppLocation"
                Write-host "Creating retired path $newPath"
				if (!(Test-Path $newPath)) 
                { [system.io.directory]::CreateDirectory($newPath) | out-null }
				New-PSDrive -Name source -PSProvider FileSystem -Root $AppLocation | Out-Null
				New-PSDrive -Name target -PSProvider FileSystem -Root $newPath | Out-Null
				Write-host "Copying files $AppLocation to $newPath"
				Copy-Item -Path source:\ -Destination target: -recurse
				Remove-PSDrive source
				Remove-PSDrive target
                

				Write-host "Deployment Type Technology $($dt.Technology)"
				##Change location -  - can only update source location per DT instead of overall App :(
				If ($dt.Technology.Tolower() -eq "msi")
				{
										
						Write-host "Changing folder source to $newPath"
						Set-CMMsiDeploymentType -ApplicationName $NewName -DeploymentTypeName ($DT.LocalizedDisplayName) -ContentLocation $newSourcePath -UninstallOption SameAsInstall
						#break
					
				}
                Else
                {
                        Set-CMScriptDeploymentType -ApplicationName $NewName -DeploymentTypeName ($DT.LocalizedDisplayName) -ContentLocation $newSourcePath -UninstallOption SameAsInstall
                }


                
                Write-host "Deleting original source folder ($AppLocation)"
				#delete source directory
				New-PSDrive -Name source -PSProvider FileSystem -Root ($AppLocation.Substring(0,$AppLocation.LastIndexOf("\"))) | Out-Null
				Get-ChildItem -Path source:\"$($AppLocation.Substring($AppLocation.LastIndexOf("\")+1))" -Recurse | Remove-Item -force -Recurse
				remove-item -Path source:\"$($AppLocation.Substring($AppLocation.LastIndexOf("\")+1))" -Force
				Remove-PSDrive source
                

                $i++ 
			}
		}
		
		##Retiring App
        Write-host "Retiring application"
		$App.SetIsExpired($true) | out-null
		Write-host " "
        
	}
}
catch
{
	Write-host "Something Had an error:" -ForegroundColor red
	Write-host "The following errors are listed:" -ForegroundColor red
	$errorMessage = $Error[0].Exception.Message
	$errorCode = "0x{0:X}" -f $Error[0].Exception.ErrorCode
    	Write-host "Error $errorCode : $errorMessage"  -ForegroundColor red
        $LogErrorCode = "Error $errorCode : $errorMessage"
    	Write-host "Full Error Message Error $($error[0].ToString())" -ForegroundColor red
	$Error.Clear()
}
finally
{ 
	#Close connection to CM12, to write log file:
    Set-Location $env:SystemRoot 
    add-content $LogPath $Log1
    add-content $LogPath $Log2
    add-content $LogPath $Log3
    add-content $LogPath $ErrorMove
    add-content $LogPath $CollLog
    add-content $LogPath $LogErrorCode
    add-content $LogPath "App Retirement complete!"
    Write-Host "Complete. Press any key to continue ..."
	$x = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}