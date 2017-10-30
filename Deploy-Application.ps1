<#
.SYNOPSIS
	This script performs the installation or uninstallation of an application(s).
.DESCRIPTION
	The script is provided as a template to perform an install or uninstall of an application(s).
	The script either performs an "Install" deployment type or an "Uninstall" deployment type.
	The install deployment type is broken down into 3 main sections/phases: Pre-Install, Install, and Post-Install.
	The script dot-sources the AppDeployToolkitMain.ps1 script which contains the logic and functions required to install or uninstall an application.
.PARAMETER DeploymentType
	The type of deployment to perform. Default is: Install.
.PARAMETER DeployMode
	Specifies whether the installation should be run in Interactive, Silent, or NonInteractive mode. Default is: Interactive. Options: Interactive = Shows dialogs, Silent = No dialogs, NonInteractive = Very silent, i.e. no blocking apps. NonInteractive mode is automatically set if it is detected that the process is not user interactive.
.PARAMETER AllowRebootPassThru
	Allows the 3010 return code (requires restart) to be passed back to the parent process (e.g. SCCM) if detected from an installation. If 3010 is passed back to SCCM, a reboot prompt will be triggered.
.PARAMETER TerminalServerMode
	Changes to "user install mode" and back to "user execute mode" for installing/uninstalling applications for Remote Destkop Session Hosts/Citrix servers.
.PARAMETER DisableLogging
	Disables logging to file for the script. Default is: $false.
.EXAMPLE
    powershell.exe -Command "& { & '.\Deploy-Application.ps1' -DeployMode 'Silent'; Exit $LastExitCode }"
.EXAMPLE
    powershell.exe -Command "& { & '.\Deploy-Application.ps1' -AllowRebootPassThru; Exit $LastExitCode }"
.EXAMPLE
    powershell.exe -Command "& { & '.\Deploy-Application.ps1' -DeploymentType 'Uninstall'; Exit $LastExitCode }"
.EXAMPLE
    Deploy-Application.exe -DeploymentType "Install" -DeployMode "Silent"
.NOTES
	Toolkit Exit Code Ranges:
	60000 - 68999: Reserved for built-in exit codes in Deploy-Application.ps1, Deploy-Application.exe, and AppDeployToolkitMain.ps1
	69000 - 69999: Recommended for user customized exit codes in Deploy-Application.ps1
	70000 - 79999: Recommended for user customized exit codes in AppDeployToolkitExtensions.ps1
.LINK
	http://psappdeploytoolkit.com
#>
[CmdletBinding()]
Param (
	[Parameter(Mandatory=$false)]
	[ValidateSet('Install','Uninstall')]
	[string]$DeploymentType = 'Install',
	[Parameter(Mandatory=$false)]
	[ValidateSet('Interactive','Silent','NonInteractive')]
	[string]$DeployMode = 'Interactive',
	[Parameter(Mandatory=$false)]
	[switch]$AllowRebootPassThru = $false,
	[Parameter(Mandatory=$false)]
	[switch]$TerminalServerMode = $false,
	[Parameter(Mandatory=$false)]
	[switch]$DisableLogging = $false
)

##*===============================================
##* Function Listings (CleanCMClientCache)
##*===============================================

#region FunctionListings

#region Function Write-Log
Function Write-Log {
<#
.EXAMPLE
    Write-Log -EventLogName 'Configuration Manager' -EventLogEntrySource 'Script' -EventLogEntryID '1' -EventLogEntryType 'Information' -EventLogEntryMessage 'Clean-CMClientCache was successful'
#>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$false,Position=0)]
        [Alias('Name')]
        [string]$EventLogName = 'Configuration Manager',
        [Parameter(Mandatory=$false,Position=1)]
        [Alias('Source')]
        [string]$EventLogEntrySource = 'Clean-CMClientCache',
        [Parameter(Mandatory=$false,Position=2)]
        [Alias('ID')]
        [int32]$EventLogEntryID = 1,
        [Parameter(Mandatory=$false,Position=3)]
        [Alias('Type')]
        [string]$EventLogEntryType = 'Information',
        [Parameter(Mandatory=$true,Position=4)]
        [Alias('Message')]
        $EventLogEntryMessage
    )

    ## Initialize log
    If (([System.Diagnostics.EventLog]::Exists($EventLogName) -eq $false) -or ([System.Diagnostics.EventLog]::SourceExists($EventLogEntrySource) -eq $false )) {
        New-EventLog -LogName $EventLogName -Source $EventLogEntrySource
    }

    $ResultString = Out-String -InputObject $Result -Width 1000
    Write-EventLog -LogName $EventLogName -Source $EventLogEntrySource -EventId $EventLogEntryID -EntryType $EventLogEntryType -Message $ResultString

    $EventLogEntryMessage | Export-Csv -Path $ResultCSV -Delimiter ';' -Encoding UTF8 -NoTypeInformation -Append -Force
    $EventLogEntryMessage | Format-Table Name,TotalDeleted`(MB`)

}
#endregion


#region Function Clean-CacheItem
Function Clean-CacheItem {
<#
.DESCRIPTION
    Removes specified SCCM cached package.
    Called by the following functions:
    Remove-CachedApplication, Remove-CachedPackage, Remove-CachedUpdate & Remove-OrphanedCacheItem
.PARAMETER CacheItemToDelete
    The cache item ID that needs to be deleted.
.PARAMETER CacheItemName
    The cache item name that needs to be deleted.
.EXAMPLE
    Clean-CacheItem -CacheItemToDelete '{234234234}' -CacheItemName 'Office2003'
#>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true,Position=0)]
        [Alias('CacheTD')]
        [string]$CacheItemToDelete,
        [Parameter(Mandatory=$true,Position=1)]
        [Alias('CacheN')]
        [string]$CacheItemName
    )

    ## Delete cache item if it's non persisted
    If ($CacheItems.ContentID -contains $CacheItemToDelete) {

        $CacheItemLocation = $CacheItems | Where-Object {$_.ContentID -Contains $CacheItemToDelete} | Select-Object -ExpandProperty Location
        $CacheItemSize =  Get-ChildItem $CacheItemLocation -Recurse -Force | Measure-Object -Property Length -Sum | Select-Object -ExpandProperty Sum

        #  Check if cache item is downloaded
        If ($CacheItemSize -gt '0.00') {

            $CMObject = New-Object -ComObject 'UIResource.UIResourceMgr'

            $CMCacheObjects = $CMObject.GetCacheInfo()
            $CMCacheObjects.GetCacheElements() | Where-Object {$_.ContentID -eq $CacheItemToDelete} |
                ForEach-Object {
                    $CMCacheObjects.DeleteCacheElement($_.CacheElementID)
                    Write-Output "Deleted: $CacheItemName"
                }

            $ResultProps = [ordered]@{
                'Name' = $CacheItemName
                'ID' = $CacheItemToDelete
                'Location' = $CacheItemLocation
                'Size(MB)' = '{0:N2}' -f ($CacheItemSize / 1MB)
                'Status' = 'Deleted!'
            }

            $Script:Result += New-Object PSObject -Property $ResultProps
        }

    }
    Else {
        Write-Output "Already Deleted: $CacheItemName ; ID: $CacheItemToDelete"
    }
}
#endregion


#region Function Remove-CachedApplication
Function Remove-CachedApplication {
<#
.DESCRIPTION
    Removes specified SCCM cached update if it's not needed anymore.
#>

    #Get list of Applications
    Try {
        $CM_Applications = Get-CimInstance -Namespace root\ccm\ClientSDK -Query 'SELECT * FROM CCM_Application' -ErrorAction Stop
    }
    Catch {
        Write-Output 'Get SCCM Application List from CIM - Failed!'
    }

    Foreach ($Application in $CM_Applications) {

        #$Application.Get()
        Foreach ($DeploymentType in $Application.AppDTs) {

            ## Get content ID for specific application deployment type
            $AppType = 'Install',$DeploymentType.Id,$DeploymentType.Revision
            $AppContent = Invoke-CimMethod -Namespace root\ccm\cimodels -ClassName CCM_AppDeliveryType -MethodName "GetContentInfo" -Arguments $AppType
						#$AppContent = Invoke-CIMMethod -Namespace root\ccm\cimodels -Class CCM_AppDeliveryType -Name GetContentInfo -ArgumentList $AppType

            If ($Application.InstallState -eq 'Installed' -and $Application.IsMachineTarget -and $AppContent.ContentID) {
                Clean-CacheItem -CacheTD $AppContent.ContentID -CacheN $Application.FullName
            }
            Else {
                $Script:ExclusionList += $AppContent.ContentID
            }

        }

    }

}
#endregion


#region Function Remove-CachedPackage
Function Remove-CachedPackage {
<#
.DESCRIPTION
    Removes specified SCCM cached package if it's not needed anymore.
#>

    Try {
        $CM_Packages = Get-CimInstance -Namespace root\ccm\ClientSDK -Query 'SELECT PackageID,PackageName,LastRunStatus,RepeatRunBehavior FROM CCM_Program' -ErrorAction Stop
    }
    Catch {
        Write-Output 'Get SCCM Package List from CIM - Failed!'
    }

    ## Check if any deployed programs in the package need the cached package and add deletion or exemption list for comparison
    ForEach ($Program in $CM_Packages) {

        #  Check if program in the package needs the cached package
        If ($Program.LastRunStatus -eq 'Succeeded' -and $Program.RepeatRunBehavior -ne 'RerunAlways' -and $Program.RepeatRunBehavior -ne 'RerunIfSuccess') {

            If ($Program.PackageID -NotIn $PackageIDDeleteTrue) {
                [Array]$PackageIDDeleteTrue += $Program.PackageID
            }

        }
        Else {

            If ($Program.PackageID -NotIn $PackageIDDeleteFalse) {
                [Array]$PackageIDDeleteFalse += $Program.PackageID
            }

        }

    }

    ## Parse Deletion List and Remove Package if not in Exemption List
    ForEach ($Package in $PackageIDDeleteTrue) {

        If ($Package -NotIn $PackageIDDeleteFalse) {
            Clean-CacheItem -CacheTD $Package.PackageID -CacheN $Package.PackageName
        }
        Else {
            $Script:ExclusionList += $Package.PackageID
        }

    }

}
#endregion


#region Function Remove-CachedUpdate
Function Remove-CachedUpdate {
<#
.DESCRIPTION
    Removes specified SCCM cached update if it's not needed anymore.
#>

    ## Get list of updates
    Try {
        $CM_Updates = Get-CimInstance -Namespace root\ccm\SoftwareUpdates\UpdatesStore -Query 'SELECT UniqueID,Title,Status FROM CCM_UpdateStatus' -ErrorAction Stop
    }
    Catch {
        Write-Output 'Get SCCM Software Update List from CIM - Failed!'
    }

    ## Check if cached updates are not needed and delete them
    ForEach ($Update in $CM_Updates) {

        If ($Update.Status -eq 'Installed') {
            Clean-CacheItem -CacheTD $Update.UniqueID -CacheN $Update.Title
        }
        Else {
            $Script:ExclusionList += $Update.UniqueID
        }

    }

}
#endregion


#region Function Remove-OrphanedCacheItem
Function Remove-OrphanedCacheItem {
<#
.DESCRIPTION
    Removes SCCM orphaned cache items not found in Applications, Packages or Update CIM Tables.
#>

    ## Check if cached updates are not needed and delete them
    ForEach ($CacheItem in $CacheItems) {

        If ($Script:ExclusionList -notcontains $CacheItem.ContentID) {
            Clean-CacheItem -CacheTD $CacheItem.ContentID -CacheN 'Orphaned Cache Item'
        }

    }

}
#endregion

#endregion

##*===============================================
##* End of Function Listings (CleanCMClientCache)
##*===============================================


Try {
	## Set the script execution policy for this process
	Try { Set-ExecutionPolicy -ExecutionPolicy 'ByPass' -Scope 'Process' -Force -ErrorAction 'Stop' } Catch { Write-Error "Failed to set the execution policy to Bypass for this process." }

	##*===============================================
	##* VARIABLE DECLARATION
	##*===============================================
	## Variables: Application
	[string]$appVendor = ''
	[string]$appName = ''
	[string]$appVersion = ''
	[string]$appArch = ''
	[string]$appLang = 'EN'
	[string]$appRevision = '01'
	[string]$appScriptVersion = '1.0.0'
	[string]$appScriptDate = '06/12/2017'
	[string]$appScriptAuthor = '<author name>'
	##*===============================================
	## Variables: Install Titles (Only set here to override defaults set by the toolkit)
	[string]$installName = ''
	[string]$installTitle = ''

	##* Do not modify section below
	#region DoNotModify

	## Variables: Exit Code
	[int32]$mainExitCode = 0

	## Variables: Script
	[string]$deployAppScriptFriendlyName = 'Deploy Application'
	[version]$deployAppScriptVersion = [version]'3.6.9'
	[string]$deployAppScriptDate = '02/12/2017'
	[hashtable]$deployAppScriptParameters = $psBoundParameters

	## Variables: Environment
	If (Test-Path -LiteralPath 'variable:HostInvocation') { $InvocationInfo = $HostInvocation } Else { $InvocationInfo = $MyInvocation }
	[string]$scriptDirectory = Split-Path -Path $InvocationInfo.MyCommand.Definition -Parent

	## Dot source the required App Deploy Toolkit Functions
	Try {
		[string]$moduleAppDeployToolkitMain = "$scriptDirectory\AppDeployToolkit\AppDeployToolkitMain.ps1"
		If (-not (Test-Path -LiteralPath $moduleAppDeployToolkitMain -PathType 'Leaf')) { Throw "Module does not exist at the specified location [$moduleAppDeployToolkitMain]." }
		If ($DisableLogging) { . $moduleAppDeployToolkitMain -DisableLogging } Else { . $moduleAppDeployToolkitMain }
	}
	Catch {
		If ($mainExitCode -eq 0){ [int32]$mainExitCode = 60008 }
		Write-Error -Message "Module [$moduleAppDeployToolkitMain] failed to load: `n$($_.Exception.Message)`n `n$($_.InvocationInfo.PositionMessage)" -ErrorAction 'Continue'
		## Exit the script, returning the exit code to SCCM
		If (Test-Path -LiteralPath 'variable:HostInvocation') { $script:ExitCode = $mainExitCode; Exit } Else { Exit $mainExitCode }
	}

	#endregion
	##* Do not modify section above
	##*===============================================
	##* END VARIABLE DECLARATION
	##*===============================================

	If ($deploymentType -ine 'Uninstall') {
		##*===============================================
		##* PRE-INSTALLATION
		##*===============================================
		[string]$installPhase = 'Pre-Installation'

		## Show Welcome Message, close applications if required, verify there is enough disk space to complete the install, and persist the prompt
		Show-InstallationWelcome -CloseApps 'iexplore' -CheckDiskSpace -PersistPrompt

		## Show Progress Message (with the default message)
		Show-InstallationProgress

		## <Perform Pre-Installation tasks here>

		<#
	  *********************************************************************************************************
		* Created by Ioan Popovici, 2015-11-13  | Requirements PowerShell 3.0                                   *
		*********************************************************************************************************
		.NOTES
				It only cleans packages, applications and updates that have a "installed" status, are not persisted, or
				are not needed anymore (Some other checks are performed). Other cache items will NOT be cleaned.
		.LINK
				https://sccm-zone.com/deleting-the-sccm-cache-the-right-way-3c1de8dc4b48
		#>


		#region Initialization

		Clear-Host

		#Delete DiskCleanup indicator so that date modified updates upon folder creation at end of script
		If (Test-Path "$envWinDir\Management\DiskCleanup") {
		   Remove-Folder -path "$envWinDir\Management\DiskCleanup"
	  }

		$Script:Result =@()
		$Script:ExclusionList =@()

		$ResultCSV = 'C:\Temp\Clean-CMClientCache.log'
		If (Test-Path $ResultCSV) {
				If ((Get-Item $ResultCSV).Length -gt 500KB) {
						Remove-Item $ResultCSV -Force | Out-Null
				}
		}

		[String]$ResultPath =  Split-Path $ResultCSV -Parent
		If ((Test-Path $ResultPath) -eq $False) {
				New-Item -Path $ResultPath -Type Directory | Out-Null
		}

		$Date = Get-Date

		#endregion

		##*===============================================
		##* INSTALLATION
		##*===============================================
		[string]$installPhase = 'Installation'

		## Handle Zero-Config MSI Installations
		If ($useDefaultMsi) {
			[hashtable]$ExecuteDefaultMSISplat =  @{ Action = 'Install'; Path = $defaultMsiFile }; If ($defaultMstFile) { $ExecuteDefaultMSISplat.Add('Transform', $defaultMstFile) }
			Execute-MSI @ExecuteDefaultMSISplat; If ($defaultMspFiles) { $defaultMspFiles | ForEach-Object { Execute-MSI -Action 'Patch' -Path $_ } }
		}

		## <Perform Installation tasks here>

		#region ScriptBody

		## Get list of all non persisted content in CCMCache, only this content will be removed
		Try {
				$CacheItems = Get-CimInstance -Namespace root\ccm\SoftMgmtAgent -Query 'SELECT ContentID,Location FROM CacheInfoEx WHERE PersistInCache != 1' -ErrorAction Stop
		}
		Catch {
		    Write-Output 'Getting SCCM Cache Info from CIM - Failed! Check if SCCM Client is Installed!'
		}

		Remove-CachedApplication
		Remove-CachedPackage
		Remove-CachedUpdate
		Remove-OrphanedCacheItem

		$Result =  $Script:Result | Sort-Object Size`(MB`) -Descending

		$TotalDeletedSize = $Result | Measure-Object -Property Size`(MB`) -Sum | Select-Object -ExpandProperty Sum
		If ($null -eq $TotalDeletedSize -or $TotalDeletedSize -eq '0.00') {
		    $TotalDeletedSize = 'Nada'
		}
		Else {
		    $TotalDeletedSize = '{0:N2}' -f $TotalDeletedSize
		    }

		$ResultProps = [ordered]@{
		    'Name' = 'Total Size of Items Deleted in MB: '+$TotalDeletedSize
		    'ID' = 'N/A'
		    'Location' = 'N/A'
		    'Size(MB)' = 'N/A'
		    'Status' = ' ***** Last Run Date: '+$Date+' *****'
		}

		$addResult = New-Object PSObject -Property $ResultProps
		$Result = [Array]$Result + $addResult
		#$Result += New-Object PSObject -Property $ResultProps

		#Write Date Registry Entry to be evaluated later by Cleanup policy's Detection Method
		New-Folder -path "C:\Windows\Management\DiskCleanup"

		#Logic for Detection method
	  #$evaluateLastrun = Get-ChildItem C:\Windows\Management | Where-Object { ($_.Name -eq "DiskCleanup") -and ($_.LastWriteTime -lt (Get-Date).AddDays(-10)) } | Select-Object Name

		#Run Hardware Inventory
		Invoke-SCCMTask 'HardwareInventory'

		Write-Log -Message $Result
		Write-Output 'Processing Finished!'

		#endregion


		##*===============================================
		##* POST-INSTALLATION
		##*===============================================
		[string]$installPhase = 'Post-Installation'

		## <Perform Post-Installation tasks here>

		## Display a message at the end of the install
		If (-not $useDefaultMsi) {}
	}
	ElseIf ($deploymentType -ieq 'Uninstall')
	{
		##*===============================================
		##* PRE-UNINSTALLATION
		##*===============================================
		[string]$installPhase = 'Pre-Uninstallation'

		## Show Welcome Message, close applications with a 60 second countdown before automatically closing
		Show-InstallationWelcome -CloseApps 'iexplore' -CloseAppsCountdown 60

		## Show Progress Message (with the default message)
		Show-InstallationProgress

		## <Perform Pre-Uninstallation tasks here>


		##*===============================================
		##* UNINSTALLATION
		##*===============================================
		[string]$installPhase = 'Uninstallation'

		## Handle Zero-Config MSI Uninstallations
		If ($useDefaultMsi) {
			[hashtable]$ExecuteDefaultMSISplat =  @{ Action = 'Uninstall'; Path = $defaultMsiFile }; If ($defaultMstFile) { $ExecuteDefaultMSISplat.Add('Transform', $defaultMstFile) }
			Execute-MSI @ExecuteDefaultMSISplat
		}

		# <Perform Uninstallation tasks here>


		##*===============================================
		##* POST-UNINSTALLATION
		##*===============================================
		[string]$installPhase = 'Post-Uninstallation'

		## <Perform Post-Uninstallation tasks here>


	}

	##*===============================================
	##* END SCRIPT BODY
	##*===============================================

	## Call the Exit-Script function to perform final cleanup operations
	Exit-Script -ExitCode $mainExitCode
}
Catch {
	[int32]$mainExitCode = 60001
	[string]$mainErrorMessage = "$(Resolve-Error)"
	Write-Log -Message $mainErrorMessage -Severity 3 -Source $deployAppScriptFriendlyName
	Show-DialogBox -Text $mainErrorMessage -Icon 'Stop'
	Exit-Script -ExitCode $mainExitCode
}
