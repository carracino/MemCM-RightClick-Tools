<#
#=======================================================================================
# Name: RetirePackage.ps1
# Version: 2.1
# Jon Carracino
# Comment: This script will retire a selected package only. Applications are handeled in seperate script!
    1.3 - fixed multiple issues with possible source paths, content copy error handling
  2.0 - updated for Azure compatibility and support of multiple site locations. 
  2.1 - Changed source server paths to reflect changes necessary for rehyradtion work. 
# 
# Usage:
#	powershell.exe -ExecutionPolicy Bypass .\RetireApplication.ps1 [Parameters]
#   
# Parameters: Had to look this up - packages\apps dont always use primary server for namespace..
#		 sdkserver - netbios format
#		 sitenamespae - root\site\site_ format
#		 packageID - given from right click context
#=======================================================================================
#>

#Set - Variables:
$sdkserver = $args[0]
$SiteNamespace = $args[1]
$SiteCode = $SiteNamespace.SubString($SiteNamespace.Indexof("site_") +5)
$PackageID = $args[2]
$Scope = "Retired Packages"
$NewRootPath = "\\server\folderlocation\retiredApps"
$LogPath = '\\server\folder\RetiredPackages.log'
 # Format Date for our Log File 
$FormattedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss" 

## Start entry in Log File:
add-content $LogPath "#########################################################"
add-content $LogPath "$PackageID : $FormattedDate - Package Retirement invoked by $env:username"


try
{
	if ($NewRootPath.substring($NewRootPath.length-1) -ne '\') { $NewRootPath+= '\' }
	"{0} {1} {2} {3} {4} {5}" -f $sdkserver, $SiteNamespace, $SiteCode, $PackageID, $Scope, $NewRootPath

	if ((Read-Host "Are you really sure you want to retire the package? (Y/N)").Tolower() -eq "n")
	{
		Write-Host "Cancelled by the user, no action taken..." -ForegroundColor Red
        add-content $LogPath "Action Canceled by User"
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

    #import CM module and set site location
	Write-Host "Importing CM12 powershell module..."
	import-module $env:SMS_ADMIN_UI_PATH.Replace("bin\i386","bin\ConfigurationManager.psd1") -force

    #Disable update notification: THIS IS NO LONGER Required ***
    #Set-CMCmdletUpdateCheck -CurrentUser -IsUpdateCheckEnabled $false

	 #ensure correct PSDrive for site exists: had to remove current PSdrive as it could have old connection reference
    Remove-PSDrive $SiteCode -force
    new-psdrive -Name $SiteCode -PSProvider "AdminUI.PS.Provider\CMSite" -Root $sdkserver
	cd "$($SiteCode):"

	#Get-Package Name and all details into variable:
    $App = Get-CMPackage -Id $PackageID
		$CurrentAppName = $App.Name
		$NewName = "Retired-$($CurrentAppName)"
        
        Write-host "Renaming Package $CurrentAppName to $NewName" 
        $Log1 = "$PackageID : Renaming Package $CurrentAppName to $NewName"
		##Renaming app to Retired-
		Set-CMPackage -Id $PackageID -NewName $NewName

		##Move Application\Package to Retired folder
		Write-host "Moving Package to Folder $Scope"
		Move-CMObject -FolderPath "$($SiteCode):\Package\Desktop\$Scope" -ObjectId $PackageID

		##Get all Deployments
		Write-host "Querying Deployment information. This may take a min....."
		$DeploymentList = Get-CMDeployment | where {$_.PackageID -eq $PackageID}
		foreach ($Deployment in $DeploymentList)
		{
			Write-host "Removing Deployment: $($Deployment.SoftwareName)"
            $Logtemp = "Removing Deployment: $($Deployment.SoftwareName)"
            $Colltemp = "Collection Review: $($Deployment.CollectionName):$($Deployment.CollectionID)"
            $CollLog = $Colltemp + "; " + $CollLog
            $Log2 = $Logtemp + "; " + $Log2   
			#Remove-CMDeployment -DeploymentId $Deployment.DeploymentID -Force -This only works on Apps :(
            #query WMI and Delete
            $PackageDeployment = Get-WmiObject -Namespace $SiteNamespace -ComputerName $sdkserver -class "SMS_Advertisement" -filter "AdvertisementID='$($Deployment.DeploymentID)'"
            $PackageDeployment.Delete()
		}

	######Get Package Source and Create new location:
				
			Write-host "Getting source location information"
            $AppLocation = $App.PkgSourcePath
            #ensure format
            if ($AppLocation.substring($AppLocation.length-1) -eq '\') { $AppLocation = $AppLocation.Substring(0, $AppLocation.Length-1) }
            $newSourcePath = "$($NewRootPath)$($CurrentAppName)_$($AppLocation.Substring($AppLocation.LastIndexOf("\")+1))\$($AppLocation.Substring($AppLocation.LastIndexOf("\")+1))"
            $newPath = "$($NewRootPath)$($CurrentAppName)_$($AppLocation.Substring($AppLocation.LastIndexOf("\")+1))"

			if (($AppLocation -eq $null) -or ($AppLocation.trim() -eq ""))
			{
				Write-host "*Unable to determine the current source location. ignoring moving content to retired folder!" -ForegroundColor yellow
                $ErrorMove = "$PackageID : Error moving source for $PackageID ; PkgSource=$($App.PkgSourcePath)"
			}
			else
			{
				##get source folder and copy files to retired folder
					
				$Log3 = "$PackageID : Previous source path: $AppLocation"
                Write-host "Creating retired path $NewPath"
				if (!(Test-Path $newPath)) { [system.io.directory]::CreateDirectory($NewPath) | out-null }
				New-PSDrive -Name source -PSProvider FileSystem -Root $AppLocation | Out-Null
				New-PSDrive -Name target -PSProvider FileSystem -Root $NewPath | Out-Null
				Write-host "Copying files $AppLocation to $NewPath"
				Copy-Item -Path source:\ -Destination target: -recurse
				Remove-PSDrive source
				Remove-PSDrive target

				Write-host "Copy Complete!"
				##Change location in package to reflect move
				
						Write-host "Changing folder source to $NewPath"
						Set-CMPackage -Id $PackageID -Path $NewSourcePath
										
				Write-host "Deleting original source folder $AppLocation"
				#delete source directory
				New-PSDrive -Name source -PSProvider FileSystem -Root ($AppLocation.Substring(0,$AppLocation.LastIndexOf("\"))) | Out-Null
				Get-ChildItem -Path source:\"$($AppLocation.Substring($AppLocation.LastIndexOf("\")+1))" -Recurse | Remove-Item -force -Recurse
				remove-item -Path source:\"$($AppLocation.Substring($AppLocation.LastIndexOf("\")+1))" -Force
				Remove-PSDrive source
		}
		
		##Retiring App
          #Only need to perform on Applications        
	
}
catch
{
	Write-host "Something Had an error:" -ForegroundColor red
	Write-host "The following errors are listed:" -ForegroundColor red
	$errorMessage = $Error[0].Exception.Message
	$errorCode = "0x{0:X}" -f $Error[0].Exception.ErrorCode
    	Write-host "Error $errorCode : $errorMessage"  -ForegroundColor red
        $LogErrorCode = "$PackageID : Error $errorCode : $errorMessage"
    	Write-host "Full Error Message Error $($error[0].ToString())" -ForegroundColor red
	$Error.Clear()
}
finally
{ 
	#Close connection to CM12, to write log file:
    Set-Location $env:SystemRoot 
    add-content $LogPath $Log1
    add-content $LogPath "$PackageID : $Log2"
    add-content $LogPath $Log3
    add-content $LogPath $ErrorMove
    add-content $LogPath "$PackageID : $CollLog"
    add-content $LogPath $LogErrorCode
    add-content $LogPath "$PackageID : Package Retirement complete!"
    Write-Host "Complete. Press any key to continue ..."
	$x = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}