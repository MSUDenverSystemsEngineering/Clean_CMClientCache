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

Try {
	## Set the script execution policy for this process
	Try { Set-ExecutionPolicy -ExecutionPolicy 'ByPass' -Scope 'Process' -Force -ErrorAction 'Stop' } Catch { Write-Error "Failed to set the execution policy to Bypass for this process." }

	##*===============================================
	##* VARIABLE DECLARATION
	##*===============================================
	## Variables: Application
	[string]$appVendor = 'SomeDude'
	[string]$appName = 'Cleans_CMClientCache'
	[string]$appVersion = ''
	[string]$appArch = ''
	[string]$appLang = 'EN'
	[string]$appRevision = '01'
	[string]$appScriptVersion = '1.0.0'
	[string]$appScriptDate = '11/3/2017'
	[string]$appScriptAuthor = 'Ioan Popvici with a pestering modification'
	# Pop's URL https://sccm-zone.com/deleting-the-sccm-cache-the-right-way-3c1de8dc4b48
	##*===============================================
	## Variables: Install Titles (Only set here to override defaults set by the toolkit)
	[string]$installName = ''
	[string]$installTitle = ''


	##*===============================================
	##* Function Listings (CleanCMClientCache)
	##*===============================================

	#region FunctionListings

	#region Function Clear-CacheItem
	Function Clear-CacheItem {
	<#
	.DESCRIPTION
	    Removes specified SCCM cached package.
	    Called by the following functions:
	    Clear-CachedApplication, Clear-CachedPackage, Clear-CachedUpdate & Clear-OrphanedSeveredCacheItem
	.PARAMETER CacheItemToDelete
	    The cache item ID that needs to be deleted.
	.PARAMETER CacheItemName
	    The cache item name that needs to be deleted.
	.EXAMPLE
	    Clear-CacheItem -CacheItemToDelete '{234234234}' -CacheItemName 'Office2003'
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
	                    Write-Log "Deleted: $($CacheItemName) ; ID: $($CacheItemToDelete) ; Location: $($CacheItemLocation)"
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
	        Write-Log "Already Deleted: $($CacheItemName) ; ID: $($CacheItemToDelete) ; Location: $($CacheItemLocation)"
	    }
	}
	#endregion


	#region Function Clear-CachedApplication
	Function Clear-CachedApplication {
	<#
	.DESCRIPTION
	    Removes specified SCCM cached update if it's not needed anymore.
	#>

	    #Get list of Applications
	    Try {
	        $CM_Applications = Get-CimInstance -Namespace root\ccm\ClientSDK -Query 'SELECT * FROM CCM_Application' -ErrorAction Stop
	    }
	    Catch {
	        Write-Log 'Get SCCM Application List from CIM - Failed!'
	    }

	    Foreach ($Application in $CM_Applications) {

	        #$Application.Get()
					$Application = $Application | Get-CimInstance

					Foreach ($DeploymentType in $Application.AppDTs) {

							#$AppType = 'Install',$DeploymentType.Id,$DeploymentType.Revision
							$AppType = @{}
							$AppType.Add('ActionType','Install')
							$AppType.Add('AppDeliveryTypeId',$DeploymentType.Id)
							$AppType.Add('Revision',[UInt32] $DeploymentType.Revision)

							#$AppContent = Invoke-WmiMethod -Namespace root\ccm\cimodels -Class CCM_AppDeliveryType -Name GetContentInfo -ArgumentList $AppType
	            $AppContent = Invoke-CimMethod -Namespace root\ccm\cimodels -ClassName CCM_AppDeliveryType -MethodName GetContentInfo -Arguments $AppType

	            If ($Application.InstallState -eq 'Installed' -and $Application.IsMachineTarget -and $AppContent.ContentID) {
									Write-Log "Calling Clear-CacheItem Function: ApplicationName: $($Application.Name); ContentID: $($AppContent.ContentID)"
									Clear-CacheItem -CacheTD $AppContent.ContentID -CacheN $Application.Name
	            }
	            Else {
									Write-Log "Excluding cached app. ApplicationName: $($Application.Name); ContentID: $($AppContent.ContentID)"
									$Script:ExclusionList += $AppContent.ContentID
	            }

	        }

	    }

	}
	#endregion


	#region Function Clear-CachedPackage
	Function Clear-CachedPackage {
	<#
	.DESCRIPTION
	    Removes specified SCCM cached package if it's not needed anymore.
	#>

	    Try {
				  #$CM_Packages = Get-WmiObject -Namespace root\ccm\ClientSDK -Query 'SELECT PackageID,PackageName,LastRunStatus,RepeatRunBehavior FROM CCM_Program' -ErrorAction Stop
	        $CM_Packages = Get-CimInstance -Namespace root\ccm\ClientSDK -Query 'SELECT PackageID,PackageName,LastRunStatus,RepeatRunBehavior FROM CCM_Program' -ErrorAction Stop
	    }
	    Catch {
	        Write-Log 'Get SCCM Package List from CIM - Failed!'
	    }

	    ## Check if any deployed programs in the package need the cached package and add deletion or exemption list for comparison
	    ForEach ($Program in $CM_Packages) {

	        #  Check if program in the package needs the cached package
	        If ($Program.LastRunStatus -eq 'Succeeded' -and $Program.RepeatRunBehavior -ne 'RerunAlways' -and $Program.RepeatRunBehavior -ne 'RerunIfSuccess') {

	            If ($Program.PackageID -NotIn $PackageIDDeleteTrue) {
									Write-Log "Including package: $($Program.PackageName)"
									Write-Log "Package Repeat Run Behavior: $($Program.RepeatRunBehavior)"
	                [Array]$PackageIDDeleteTrue += $Program.PackageID
	            }

	        }
	        Else {

	            If ($Program.PackageID -NotIn $PackageIDDeleteFalse) {
									Write-Log "Excluding package: $($Program.PackageName)"
									Write-Log "Package Repeat Run Behavior: $($Program.RepeatRunBehavior)"
	                [Array]$PackageIDDeleteFalse += $Program.PackageID
	            }

	        }

	    }

	    ## Parse Deletion List and Remove Package if not in Exemption List
	    ForEach ($Package in $PackageIDDeleteTrue) {

	        If ($Package -NotIn $PackageIDDeleteFalse) {
	            Clear-CacheItem -CacheTD $Package.PackageID -CacheN $Package.PackageName
	        }
	        Else {
	            $Script:ExclusionList += $Package.PackageID
	        }

	    }

	}
	#endregion


	#region Function Clear-CachedUpdate
	Function Clear-CachedUpdate {
	<#
	.DESCRIPTION
	    Removes specified SCCM cached update if it's not needed anymore.
	#>

	    ## Get list of updates
	    Try {
					#$CM_Updates = Get-WmiObject -Namespace root\ccm\SoftwareUpdates\UpdatesStore -Query 'SELECT UniqueID,Title,Status FROM CCM_UpdateStatus' -ErrorAction Stop
	        $CM_Updates = Get-CimInstance -Namespace root\ccm\SoftwareUpdates\UpdatesStore -Query 'SELECT UniqueID,Title,Status FROM CCM_UpdateStatus' -ErrorAction Stop
	    }
	    Catch {
	        Write-Output 'Get SCCM Software Update List from CIM - Failed!'
	    }

	    ## Check if cached updates are not needed and delete them
	    ForEach ($Update in $CM_Updates) {

	        If ($Update.Status -eq 'Installed') {
	            Clear-CacheItem -CacheTD $Update.UniqueID -CacheN $Update.Title
	        }
	        Else {
	            $Script:ExclusionList += $Update.UniqueID
	        }

	    }

	}
	#endregion


	#region Function Clear-OrphanedSeveredCacheItem
	Function Clear-OrphanedSeveredCacheItem {
	<#
	.DESCRIPTION
	    Removes SCCM orphaned cache items not found in Applications, Packages or Update CIM Tables.
	#>
			#Orphaned - CCMCache Index table contains an entry for Content not found as an Application, Package or Update deployed to the client
			#Severed - Folder no longer listed as an entry in CCMCache Index table, yet it is present at c:\windows\CCMCache

	    ## Check if cached updates are not needed and delete them
	    ForEach ($CacheItem in $CacheItems) {

	        If ($Script:ExclusionList -notcontains $CacheItem.ContentID) {
							Write-Log "Evaluating Orphaned Cache Item: $($CacheItem.ContentID)"
	            Clear-CacheItem -CacheTD $CacheItem.ContentID -CacheN 'Orphaned Cache Item'
	        }

			}

			#Building Arrays with Cache folder locations
			$cacheFolders = Get-ChildItem $envWinDir\ccmcache -Directory | Select FullName
			$CacheItemsLocation =@()
			ForEach ($CacheItem in $CacheItems) {
						$CacheItemsLocation += $CacheItem.Location
			}

			#Checking for any pending downloads since they are not listed in cache till after downloaded.
			ForEach ($cacheFolder in $cacheFolders) {
				If ($cacheFolder.FullName.EndsWith(".BDRTEMP")) {
						$CacheItemsLocation += $cacheFolder.FullName
						$CacheItemsLocation += $cacheFolder.FullName.Replace(".BDRTEMP", "")
				}
			}

			#Remove folders severed from CCMCache index Table
			ForEach ($cacheFolder in $cacheFolders) {
					If ($CacheItemsLocation -notcontains $cacheFolder.FullName) {
						Write-Log "Removing Severed Cache folder: $($cacheFolder.FullName)"
						Remove-File -Path $cacheFolder.FullName -Recurse
					}
			}

	}
	#endregion

	#endregion

	##*===============================================
	##* End of Function Listings (CleanCMClientCache)
	##*===============================================


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

		#Delete DiskCleanup indicator so that date modified updates upon folder creation at end of script
		If (Test-Path "$envWinDir\Management\DiskCleanup") {
		   Remove-Folder -path "$envWinDir\Management\DiskCleanup"
	  }

		$Script:Result =@()
		$Script:ExclusionList =@()
		$Date = Get-Date


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

		## Get list of all non persisted content in CCMCache, only this content will be removed
		Try {
				$CacheItems = Get-CimInstance -Namespace root\ccm\SoftMgmtAgent -Query 'SELECT ContentID,Location FROM CacheInfoEx WHERE PersistInCache != 1' -ErrorAction Stop
		}
		Catch {
		    Write-Output 'Failed getting SCCM Cache Info using CIM - Check if SCCM Client is Installed!'
		}

		Clear-CachedApplication
		Clear-CachedPackage
		Clear-CachedUpdate
		Clear-OrphanedSeveredCacheItem

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

		#$Result += New-Object PSObject -Property $ResultProps
		$addResult = New-Object PSObject -Property $ResultProps
		$Result = [Array]$Result + $addResult

		#Create folder to be evaluated later by SCCM policy's Detection Method
		New-Folder -path "C:\Windows\Management\DiskCleanup"

		Invoke-SCCMTask 'HardwareInventory'

		Write-Log $Result

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
	Write-Log $mainErrorMessage
	Show-DialogBox -Text $mainErrorMessage -Icon 'Stop'
	Exit-Script -ExitCode $mainExitCode
}
