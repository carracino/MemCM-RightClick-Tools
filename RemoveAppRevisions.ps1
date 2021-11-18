# SCCM console Right click Tool
# To be installed in console extension location. 
# ####MUST ADD Site server info in variables below#########

<#[CmdletBinding()]
Param(
    [Parameter(Mandatory = $True, Position = 1)]
    [string] $ApplicationName
)
#>

#set site variables:
$ApplicationName = $args[0]
$sdkserver = "PrimaryServer.consanto.com"
$SiteCode = "SITECODEHERE"

Try {
    Import-Module (Join-Path $(Split-Path $env:SMS_ADMIN_UI_PATH) ConfigurationManager.psd1) -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
}
Catch {
    Write-host -Message 'Importing SCCM PSH module - Failed!'
    Read-Host -Prompt "Press ENTER to exit"
    
}
#  Get the CMSITE SiteCode and change connection context

#ensure correct PSDrive for site exists:
Remove-PSDrive $SiteCode -force		
new-psdrive -Name $SiteCode -PSProvider "AdminUI.PS.Provider\CMSite" -Root $sdkserver


#  Change the connection context
Try {
    Set-Location "$($SiteCode):\"
}
Catch {
    Write-host -Message 'Set location to Site Drive - Failed!'
    Read-Host -Prompt "Press ENTER to exit"
}


write-host $MyInvocation.MyCommand.Name
write-host "Removing old revisions from:"$ApplicationName
$flag = $true
$cmApp = Get-CMApplication -name $ApplicationName
$cmAppRevision = $cmApp | Get-CMApplicationRevisionHistory
write-host $cmAppRevision
for ($i = 0; $i -lt $cmAppRevision.Count - 1; $i++) {
    write-host "Removing revision: "$cmAppRevision[$i].civersion
    Remove-CMApplicationRevisionHistory -Id $cmAppRevision[$i].ci_id -Revision $cmAppRevision[$i].civersion -force -Verbose
    $flag = $false
}
if ($flag) {write-host "No old revisions to remove!"}
Write-host "Finished!"
Read-Host -Prompt "Press ENTER to exit"