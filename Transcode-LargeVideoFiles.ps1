<#
.SYNOPSIS
    Grab each file and determine its size, if larger than 500mb. transcode and replace.
.DESCRIPTION
    To get ffmpeg to display a progress status, I had to first get the video duration using ffprobe.
    Using ffprobes value and redirecting ffmpeg stanradr error output to a log, I was able to grab
    the last line in the log and find the current transcode spot in the timeline and build a progress
    bar actively showing ffmpeg's percentage.
.NOTES
    Make sure to change the variables paths to your directory
.LINK
     - comskip.exe (entire zipped directory) --> https://www.videohelp.com/software/Comskip/old-versions#downloadold
     - ffmpeg.exe --> https://ffmpeg.org/download.html
     - ffprobe.exe (comes with ffmpeg) --> https://ffmpeg.org/download.html
     - PlexComskip.py (optional) --> https://github.com/ekim1337/PlexComskip
     - Python 2.7 (optional) --> https://www.python.org/downloads/release/python-2713/
#>

## Variables: Script Name and Script Paths
[string]$scriptPath = $MyInvocation.MyCommand.Definition
[string]$scriptName = [IO.Path]::GetFileNameWithoutExtension($scriptPath)
[string]$scriptRoot = Split-Path -Path $scriptPath -Parent
[string]$invokingScript = (Get-Variable -Name 'MyInvocation').Value.ScriptName

#  Get the invoking script directory
If ($invokingScript) {
	#  If this script was invoked by another script
	[string]$scriptParentPath = Split-Path -Path $invokingScript -Parent
}
Else {
	#  If this script was not invoked by another script, fall back to the directory one level above this script
	[string]$scriptParentPath = (Get-Item -LiteralPath $scriptRoot).Parent.FullName
}


##*===============================================
##* FUNCTIONS
##*===============================================
function Get-HugeDirStats($directory) {
    function go($dir, $stats)
    {
        foreach ($f in [system.io.Directory]::EnumerateFiles($dir))
        {
            $stats.Count++
            $stats.Size += (New-Object io.FileInfo $f).Length
        }
        foreach ($d in [system.io.directory]::EnumerateDirectories($dir))
        {
            go $d $stats
        }
    }
    $statistics = New-Object PsObject -Property @{Count = 0; Size = [long]0 }
    go $directory $statistics

    $statistics
}

function Convert-ToBytes($num)
{
    $suffix = "B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"
    $index = 0
    while ($num -gt 1kb)
    {
        $num = $num / 1kb
        $index++
    }

    "{0:N1} {1}" -f $num, $suffix[$index]
}

#region Function Execute-Process
Function Execute-Process {
<#
.SYNOPSIS
	Execute a process with optional arguments, working directory, window style.
.DESCRIPTION
	Executes a process, e.g. a file included in the Files directory of the App Deploy Toolkit, or a file on the local machine.
	Provides various options for handling the return codes (see Parameters).
.PARAMETER Path
	Path to the file to be executed. If the file is located directly in the "Files" directory of the App Deploy Toolkit, only the file name needs to be specified.
	Otherwise, the full path of the file must be specified. If the files is in a subdirectory of "Files", use the "$dirFiles" variable as shown in the example.
.PARAMETER Parameters
	Arguments to be passed to the executable
.PARAMETER WindowStyle
	Style of the window of the process executed. Options: Normal, Hidden, Maximized, Minimized. Default: Normal.
	Note: Not all processes honor the "Hidden" flag. If it it not working, then check the command line options for the process being executed to see it has a silent option.
.PARAMETER CreateNoWindow
	Specifies whether the process should be started with a new window to contain it. Default is false.
.PARAMETER WorkingDirectory
	The working directory used for executing the process. Defaults to the directory of the file being executed.
.PARAMETER NoWait
	Immediately continue after executing the process.
.PARAMETER PassThru
	Returns ExitCode, STDOut, and STDErr output from the process.
.PARAMETER IgnoreExitCodes
	List the exit codes to ignore.
.PARAMETER ContinueOnError
	Continue if an exit code is returned by the process that is not recognized by the App Deploy Toolkit. Default: $false.
.EXAMPLE
	Execute-Process -Path 'uninstall_flash_player_64bit.exe' -Parameters '/uninstall' -WindowStyle 'Hidden'
	If the file is in the "Files" directory of the App Deploy Toolkit, only the file name needs to be specified.
.EXAMPLE
	Execute-Process -Path "$dirFiles\Bin\setup.exe" -Parameters '/S' -WindowStyle 'Hidden'
.EXAMPLE
	Execute-Process -Path 'setup.exe' -Parameters '/S' -IgnoreExitCodes '1,2'
.EXAMPLE
	Execute-Process -Path 'setup.exe' -Parameters "-s -f2`"$configToolkitLogDir\$installName.log`""
	Launch InstallShield "setup.exe" from the ".\Files" sub-directory and force log files to the logging folder.
.EXAMPLE
	Execute-Process -Path 'setup.exe' -Parameters "/s /v`"ALLUSERS=1 /qn /L* \`"$configToolkitLogDir\$installName.log`"`""
	Launch InstallShield "setup.exe" with embedded MSI and force log files to the logging folder.
.NOTES
    Taken from http://psappdeploytoolkit.com
.LINK

#>
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory=$true)]
		[Alias('FilePath')]
		[ValidateNotNullorEmpty()]
		[string]$Path,
		[Parameter(Mandatory=$false)]
		[Alias('Arguments')]
		[ValidateNotNullorEmpty()]
		[string[]]$Parameters,
		[Parameter(Mandatory=$false)]
		[ValidateSet('Normal','Hidden','Maximized','Minimized')]
		[Diagnostics.ProcessWindowStyle]$WindowStyle = 'Normal',
		[Parameter(Mandatory=$false)]
		[ValidateNotNullorEmpty()]
		[switch]$CreateNoWindow = $false,
		[Parameter(Mandatory=$false)]
		[ValidateNotNullorEmpty()]
		[string]$WorkingDirectory,
		[Parameter(Mandatory=$false)]
		[switch]$NoWait = $false,
		[Parameter(Mandatory=$false)]
		[switch]$PassThru = $false,
		[Parameter(Mandatory=$false)]
		[ValidateNotNullorEmpty()]
		[string]$IgnoreExitCodes,
		[Parameter(Mandatory=$false)]
		[ValidateNotNullorEmpty()]
		[boolean]$ContinueOnError = $false
	)

	Begin {
		## Get the name of this function and write header
		[string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
	}
	Process {
		Try {
			$private:returnCode = $null

			## Validate and find the fully qualified path for the $Path variable.
			If (([IO.Path]::IsPathRooted($Path)) -and ([IO.Path]::HasExtension($Path))) {
				If (-not (Test-Path -LiteralPath $Path -PathType 'Leaf' -ErrorAction 'Stop')) {
					Throw "File [$Path] not found."
				}
			}
			Else {
				#  The first directory to search will be the 'Files' subdirectory of the script directory
				[string]$PathFolders = $dirFiles
				#  Add the current location of the console (Windows always searches this location first)
				[string]$PathFolders = $PathFolders + ';' + (Get-Location -PSProvider 'FileSystem').Path
				#  Add the new path locations to the PATH environment variable
				$env:PATH = $PathFolders + ';' + $env:PATH

				#  Get the fully qualified path for the file. Get-Command searches PATH environment variable to find this value.
				[string]$FullyQualifiedPath = Get-Command -Name $Path -CommandType 'Application' -TotalCount 1 -Syntax -ErrorAction 'Stop'

				#  Revert the PATH environment variable to it's original value
				$env:PATH = $env:PATH -replace [regex]::Escape($PathFolders + ';'), ''

				If ($FullyQualifiedPath) {
					$Path = $FullyQualifiedPath
				}
				Else {
					Throw "[$Path] contains an invalid path or file name."
				}
			}

			## Set the Working directory (if not specified)
			If (-not $WorkingDirectory) { $WorkingDirectory = Split-Path -Path $Path -Parent -ErrorAction 'Stop' }

			Try {
				## Disable Zone checking to prevent warnings when running executables
				$env:SEE_MASK_NOZONECHECKS = 1

				## Using this variable allows capture of exceptions from .NET methods. Private scope only changes value for current function.
				$ErrorActionPreference = 'Stop'

				## Define process
				$processStartInfo = New-Object -TypeName 'System.Diagnostics.ProcessStartInfo' -ErrorAction 'Stop'
				$processStartInfo.FileName = $Path
				$processStartInfo.WorkingDirectory = $WorkingDirectory
				$processStartInfo.UseShellExecute = $false
				$processStartInfo.ErrorDialog = $false
				$processStartInfo.RedirectStandardOutput = $true
				$processStartInfo.RedirectStandardError = $true
				$processStartInfo.CreateNoWindow = $CreateNoWindow
				If ($Parameters) { $processStartInfo.Arguments = $Parameters }
				If ($windowStyle) { $processStartInfo.WindowStyle = $WindowStyle }
				$process = New-Object -TypeName 'System.Diagnostics.Process' -ErrorAction 'Stop'
				$process.StartInfo = $processStartInfo

				## Add event handler to capture process's standard output redirection
				[scriptblock]$processEventHandler = { If (-not [string]::IsNullOrEmpty($EventArgs.Data)) { $Event.MessageData.AppendLine($EventArgs.Data) } }
				$stdOutBuilder = New-Object -TypeName 'System.Text.StringBuilder' -ArgumentList ''
				$stdOutEvent = Register-ObjectEvent -InputObject $process -Action $processEventHandler -EventName 'OutputDataReceived' -MessageData $stdOutBuilder -ErrorAction 'Stop'

				## Start Process
				If ($Parameters) {
					Write-Log -Message "Executing [$Path $Parameters]..." -Source ${CmdletName} -Severity 4 -WriteHost -MsgPrefix (Pad-PrefixOutput -Prefix "Running Command"  -UpperCase)
				}
				Else {
					Write-Log -Message "Executing [$Path]..." -Source $TranscodeJobName -Severity 4 -WriteHost -MsgPrefix (Pad-PrefixOutput -Prefix "Running Command"  -UpperCase)
				}
				[boolean]$processStarted = $process.Start()

				If ($NoWait) {
					Write-Log -Message 'NoWait parameter specified. Continuing without waiting for exit code...' -Source ${CmdletName}
				}
				Else {
					$process.BeginOutputReadLine()
					$stdErr = $($process.StandardError.ReadToEnd()).ToString() -replace $null,''

					## Instructs the Process component to wait indefinitely for the associated process to exit.
					$process.WaitForExit()

					## HasExited indicates that the associated process has terminated, either normally or abnormally. Wait until HasExited returns $true.
					While (-not ($process.HasExited)) { $process.Refresh(); Start-Start-Sleep -Seconds 1 }

					## Get the exit code for the process
					Try {
						[int32]$returnCode = $process.ExitCode
					}
					Catch [System.Management.Automation.PSInvalidCastException] {
						#  Catch exit codes that are out of int32 range
						[int32]$returnCode = 60013
					}

					## Unregister standard output event to retrieve process output
					If ($stdOutEvent) { Unregister-Event -SourceIdentifier $stdOutEvent.Name -ErrorAction 'Stop'; $stdOutEvent = $null }
					$stdOut = $stdOutBuilder.ToString() -replace $null,''
                    If(!$stdOut){
                        $stdOut = $($process.StandardOutput.ReadToEnd()).ToString() -replace $null,''
                    }

				}
			}
			Finally {
				## Make sure the standard output event is unregistered
				If ($stdOutEvent) { Unregister-Event -SourceIdentifier $stdOutEvent.Name -ErrorAction 'Stop'}

				## Free resources associated with the process, this does not cause process to exit
				If ($process) { $process.Close() }

				## Re-enable Zone checking
				Remove-Item -LiteralPath 'env:SEE_MASK_NOZONECHECKS' -ErrorAction 'SilentlyContinue'
			}

			If (-not $NoWait) {
				## Check to see whether we should ignore exit codes
				$ignoreExitCodeMatch = $false
				If ($ignoreExitCodes) {
					#  Split the processes on a comma
					[int32[]]$ignoreExitCodesArray = $ignoreExitCodes -split ','
					ForEach ($ignoreCode in $ignoreExitCodesArray) {
						If ($returnCode -eq $ignoreCode) { $ignoreExitCodeMatch = $true }
					}
				}
				#  Or always ignore exit codes
				If ($ContinueOnError) { $ignoreExitCodeMatch = $true }

				## If the passthru switch is specified, return the exit code and any output from process
				If ($PassThru) {
					[psobject]$ExecutionResults = New-Object -TypeName 'PSObject' -Property @{ ExitCode = $returnCode; StdOut = $stdOut; StdErr = $stdErr }
					Write-Output -InputObject $ExecutionResults
				}
				ElseIf ($ignoreExitCodeMatch) {
					Write-Log -Message "[$Path] Execution complete and the exit code [$returncode] is being ignored." -Source ${CmdletName}
				}
				ElseIf ($returnCode -eq 0) {
					Write-Log -Message "[$Path] Execution completed successfully with exit code [$returnCode]." -Source ${CmdletName}
				}
				Else {
					Write-Log -Message "[$Path] Execution failed with exit code [$returnCode]." -Severity 3 -Source ${CmdletName}
					Exit -ExitCode $returnCode
				}
			}
		}
		Catch {
			If ($PassThru) {
				[psobject]$ExecutionResults = New-Object -TypeName 'PSObject' -Property @{ ExitCode = $returnCode; StdOut = If ($stdOut) { $stdOut } Else { '' }; StdErr = If ($stdErr) { $stdErr } Else { '' } }
				Write-Output -InputObject $ExecutionResults
			}
			Else {
				Exit -ExitCode $returnCode
			}
		}
	}
	End {

	}
}
#endregion


Function Write-Log {
<#
.SYNOPSIS
	Write messages to a log file in CMTrace.exe compatible format or Legacy text file format.
.DESCRIPTION
	Write messages to a log file in CMTrace.exe compatible format or Legacy text file format and optionally display in the console.
.PARAMETER Message
	The message to write to the log file or output to the console.
.PARAMETER Severity
	Defines message type. When writing to console or CMTrace.exe log format, it allows highlighting of message type.
	Options: 0,1,4,5 = Information (default), 2 = Warning (highlighted in yellow), 3 = Error (highlighted in red)
.PARAMETER Source
	The source of the message being logged.
.PARAMETER LogFile
	Set the log and path of the log file.
.PARAMETER WriteHost
	Write the log message to the console.
    The Severity sets the color:
.PARAMETER ContinueOnError
	Suppress writing log message to console on failure to write message to log file. Default is: $true.
.PARAMETER PassThru
	Return the message that was passed to the function
.EXAMPLE
	Write-Log -Message "Installing patch MS15-031" -Source 'Add-Patch' -LogType 'CMTrace'
.EXAMPLE
	Write-Log -Message "Script is running on Windows 8" -Source 'Test-ValidOS' -LogType 'Legacy'
.NOTES
    Taken from http://psappdeploytoolkit.com
.LINK

#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
		[AllowEmptyCollection()]
		[Alias('Text')]
		[string[]]$Message,
        [Parameter(Mandatory=$false,Position=1)]
		[ValidateNotNullorEmpty()]
        [Alias('Prefix')]
        [string]$MsgPrefix,
        [Parameter(Mandatory=$false,Position=2)]
		[ValidateRange(0,5)]
		[int16]$Severity = 1,
		[Parameter(Mandatory=$false,Position=3)]
		[ValidateNotNull()]
		[string]$Source = '',
        [Parameter(Mandatory=$false,Position=4)]
		[ValidateNotNullorEmpty()]
		[switch]$WriteHost,
        [Parameter(Mandatory=$false,Position=5)]
		[ValidateNotNullorEmpty()]
        [switch]$NewLine,
        [Parameter(Mandatory=$false,Position=6)]
		[ValidateNotNullorEmpty()]
		[string]$LogFile = $global:LogFilePath,
		[Parameter(Mandatory=$false,Position=7)]
		[ValidateNotNullorEmpty()]
		[boolean]$ContinueOnError = $true,
		[Parameter(Mandatory=$false,Position=8)]
		[switch]$PassThru = $false

    )
    Begin {
		## Get the name of this function
		[string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name

		## Logging Variables
		#  Log file date/time
		[string]$LogTime = (Get-Date -Format 'HH:mm:ss.fff').ToString()
		[string]$LogDate = (Get-Date -Format 'MM-dd-yyyy').ToString()
		[int32]$script:LogTimeZoneBias = [timezone]::CurrentTimeZone.GetUtcOffset([datetime]::Now).TotalMinutes
		[string]$LogTimePlusBias = $LogTime + $script:LogTimeZoneBias
		#  Get the file name of the source script
		Try {
			If ($script:MyInvocation.Value.ScriptName) {
				[string]$ScriptSource = Split-Path -Path $script:MyInvocation.Value.ScriptName -Leaf -ErrorAction 'Stop'
			}
			Else {
				[string]$ScriptSource = Split-Path -Path $script:MyInvocation.MyCommand.Definition -Leaf -ErrorAction 'Stop'
			}
		}
		Catch {
			$ScriptSource = ''
		}

        ## Create script block for generating CMTrace.exe compatible log entry
		[scriptblock]$CMTraceLogString = {
			Param (
				[string]$lMessage,
				[string]$lSource,
				[int16]$lSeverity
			)
			"<![LOG[$lMessage]LOG]!>" + "<time=`"$LogTimePlusBias`" " + "date=`"$LogDate`" " + "component=`"$lSource`" " + "context=`"$([Security.Principal.WindowsIdentity]::GetCurrent().Name)`" " + "type=`"$lSeverity`" " + "thread=`"$PID`" " + "file=`"$ScriptSource`">"
		}

		## Create script block for writing log entry to the console
		[scriptblock]$WriteLogLineToHost = {
			Param (
				[string]$lTextLogLine,
				[int16]$lSeverity
			)
			If ($WriteHost) {
				#  Only output using color options if running in a host which supports colors.
				If ($Host.UI.RawUI.ForegroundColor) {
					Switch ($lSeverity) {
                        5 { Write-Host -Object $lTextLogLine -ForegroundColor 'Gray' -BackgroundColor 'Black'}
                        4 { Write-Host -Object $lTextLogLine -ForegroundColor 'Cyan' -BackgroundColor 'Black'}
						3 { Write-Host -Object $lTextLogLine -ForegroundColor 'Red' -BackgroundColor 'Black'}
						2 { Write-Host -Object $lTextLogLine -ForegroundColor 'Yellow' -BackgroundColor 'Black'}
						1 { Write-Host -Object $lTextLogLine  -ForegroundColor 'White' -BackgroundColor 'Black'}
                        0 { Write-Host -Object $lTextLogLine -ForegroundColor 'Green' -BackgroundColor 'Black'}
					}
				}
				#  If executing "powershell.exe -File <filename>.ps1 > log.txt", then all the Write-Host calls are converted to Write-Output calls so that they are included in the text log.
				Else {
					Write-Output -InputObject $lTextLogLine
				}
			}
		}

        ## Exit function if logging to file is disabled and logging to console host is disabled
		If (($DisableLogging) -and (-not $WriteHost)) { [boolean]$DisableLogging = $true; Return }
		## Exit Begin block if logging is disabled
		If ($DisableLogging) { Return }

        ## Dis-assemble the Log file argument to get directory and name
		[string]$LogFileDirectory = Split-Path -Path $LogFile -Parent
        [string]$LogFileName = Split-Path -Path $LogFile -Leaf

        ## Create the directory Where-Object the log file will be saved
		If (-not (Test-Path -LiteralPath $LogFileDirectory -PathType 'Container')) {
			Try {
				$null = New-Item -Path $LogFileDirectory -Type 'Directory' -Force -ErrorAction 'Stop'
			}
			Catch {
				[boolean]$DisableLogging = $true
				#  If error creating directory, write message to console
				If (-not $ContinueOnError) {
					Write-Host -Object "[$LogDate $LogTime] [${CmdletName}] $ScriptSection :: Failed to create the log directory [$LogFileDirectory]. `n$(Resolve-Error)" -ForegroundColor 'Red'
				}
				Return
			}
		}

		## Assemble the fully qualified path to the log file
		[string]$LogFilePath = Join-Path -Path $LogFileDirectory -ChildPath $LogFileName

    }
	Process {
        ## Exit function if logging is disabled
		If ($DisableLogging) { Return }

        Switch ($lSeverity)
            {
                5 { $Severity = 1 }
                4 { $Severity = 1 }
				3 { $Severity = 3 }
				2 { $Severity = 2 }
				1 { $Severity = 1 }
                0 { $Severity = 1 }
            }

        ## If the message is not $null or empty, create the log entry for the different logging methods
		[string]$ConsoleLogLine = ''

		#  Create the CMTrace log message

		#  Create a Console and Legacy "text" log entry
		[string]$LegacyMsg = "[$LogDate $LogTime]"
		If ($MsgPrefix) {
			[string]$ConsoleLogLine = "$LegacyMsg [$MsgPrefix] :: $Message"
		}
		Else {
			[string]$ConsoleLogLine = "$LegacyMsg :: $Message"
		}

        ## Execute script block to create the CMTrace.exe compatible log entry
		[string]$CMTraceLogLine = & $CMTraceLogString -lMessage $Message -lSource $Source -lSeverity $Severity

		[string]$LogLine = $CMTraceLogLine

        Try {
			$LogLine | Out-File -FilePath $LogFilePath -Append -NoClobber -Force -Encoding 'UTF8' -ErrorAction 'Stop'
		}
		Catch {
			If (-not $ContinueOnError) {
				Write-Host -Object "[$LogDate $LogTime] [$ScriptSection] [${CmdletName}] :: Failed to write message [$Message] to the log file [$LogFilePath]." -ForegroundColor 'Red'
			}
		}

        ## Execute script block to write the log entry to the console if $WriteHost is $true
		& $WriteLogLineToHost -lTextLogLine $ConsoleLogLine -lSeverity $Severity
    }
	End {
        If ($PassThru) { Write-Output -InputObject $Message }
    }
}

Function Pad-Counter {
    Param (
    [string]$Number,
    [int32]$MaxPad
    )

    return $Number.PadLeft($MaxPad,"0")
}

Function Pad-PrefixOutput {

    Param (
    [Parameter(Mandatory=$true)]
    [string]$Prefix,
    [switch]$UpperCase,
    [int32]$MaxPad = 20
    )

    If($Prefix.Length -ne $MaxPad){
        $addspace = $MaxPad - $Prefix.Length
        $newPrefix = $Prefix + (' ' * $addspace)
    }

    If($UpperCase){
        return $newPrefix.ToUpper()
    }Else{
        return $newPrefix
    }
}

Function Start-FFMPEGProcess {
    Param (
    [boolean]$DisplayProgress,
    [switch]$Passes
    )

	<#
	$ffmpegPassArgs =   "-i ""$($file.FullName)"" -vcodec libx264 -ac 1 -vpre fastfirstpass -pass 1 ""$NewFileFullPath""",
                       "-i ""$($file.FullName)"" -vcodec libx264 -ac 1 -vpre normal -pass 2 ""$NewFileFullPath"""
	#>
	$ffmpegPassArgs =   "-i ""$($file.FullName)"" -vcodec libxvid -q:v 5 -s 640x480 -aspect 640:480 -r 30 -g 300 -bf 2 -acodec libmp3lame -ab 160k -ar 32000 -async 32000 -ac 2 -pass 1 -an -f rawvideo -y ""$NullFileFullPath""",
                        "-i ""$($file.FullName)"" -vcodec libxvid -q:v 5 -s 640x480 -aspect 640:480 -r 30 -g 300 -bf 2 -acodec libmp3lame -ab 160k -ar 32000 -async 32000 -ac 2 -pass 2 -y ""$NewFileFullPath"""
   
    If($Passes)
    {
        $PassCount = 1
        Foreach ($Arg in $ffmpegPassArgs){

            If($DisplayProgress){
                Write-Log -Message "Executing [$FFMpegPath $Arg]..." -Source ("FFMPEG" + $PassCount + "PASS") -Severity 4 -WriteHost -MsgPrefix (Pad-PrefixOutput -Prefix "Running Command"  -UpperCase)
                $ffmpeg = Start-Process $FFMpegPath -ArgumentList $Arg -RedirectStandardError "$TranscodeLogDir\$GUID.log" -WindowStyle Hidden -PassThru
                #progress bar monitors the trancoding log for time duration and ends when process has exited
                Start-Start-Sleep 3
                Do{
                    Start-Start-Sleep 1
                    $ffmpegProgress = [regex]::split((Get-content "$TranscodeLogDir\$GUID.log" | Select-Object -Last 1), '(,|\s+)') | Where-Object {$_ -like "time=*"}
                    If($ffmpegProgress){
                        $gettimevalue = [TimeSpan]::Parse(($ffmpegProgress.Split("=")[1]))
                        $starttime = $gettimevalue.ToString("hh\:mm\:ss\,fff") 
                        $a = [datetime]::ParseExact($starttime,"HH:mm:ss,fff",$null)
                        $ffmpegTimelapse = (New-TimeSpan -Start (Get-Date).Date -End $a).TotalSeconds
                        $ffmpegPercent = $ffmpegTimelapse / $totalTime * 100
                        Write-Progress -id 2 -Activity ("Transcoding {0}" -f $file.FullName) -PercentComplete $ffmpegPercent -Status ("Video Pass {0} is {1:N2}% completed..." -f $PassCount,$ffmpegPercent)
                    }

                }Until ($ffmpeg.HasExited)
            }
            Else{
                #build new filename and path for pass
                $ffmpeg = Execute-Process -Path $FFMpegPath -Parameters $Arg -CreateNoWindow -PassThru
            }
            $PassCount = $PassCount +1
        }

    }
    Else {
        If($DisplayProgress){
     
            Write-Log -Message ("Procssing new file [{0}]" -f $NewFileFullPath) -Source $TranscodeJobName -Severity 5 -WriteHost -MsgPrefix $FileWriteHostPrefix 
            Write-Log -Message "Executing [$FFMpegPath $ffmpegCombinedArgs]..." -Source "FFMPEG" -Severity 4 -WriteHost -MsgPrefix (Pad-PrefixOutput -Prefix "Running Command"  -UpperCase)
            $ffmpeg = Start-Process -FilePath $FFMpegPath -ArgumentList $ffmpegCombinedArgs -RedirectStandardError "$TranscodeLogDir\$GUID.log" -WindowStyle Hidden -PassThru
            #progress bar monitors the trancoding log for time duration and ends when process has exited
            Start-Start-Sleep 3
            Do{
                Start-Start-Sleep 1
                #parse log every second, get the last line
                $ffmpegProgress = [regex]::split((Get-content "$TranscodeLogDir\$GUID.log" | -ObSelect-Object -Last 1), '(,|\s+)') | Where-Object {$_ -like "time=*"}
                #sometime the last line may not have a time value, only display progress when it does
                If($ffmpegProgress){
                    #The time value is in time-HH.MM.SS.mm, split it off the = and convert it to timespan format
                    $gettimevalue = [TimeSpan]::Parse(($ffmpegProgress.Split("=")[1]))
                    #send it to a string to be converted to datetime
                    $starttime = $gettimevalue.ToString("hh\:mm\:ss\,fff") 
                    $a = [datetime]::ParseExact($starttime,"HH:mm:ss,fff",$null)
                    #now convert it into seconds to match ffprobe duration format
                    $ffmpegTimelapse = (New-TimeSpan -Start (Get-Date).Date -End $a).TotalSeconds
                    #divide them to get the percentage
                    $ffmpegPercent = $ffmpegTimelapse / $totalTime * 100
                    #display time
                    Write-Progress -id 2 -Activity ("Transcoding {0}" -f $file.FullName) -PercentComplete $ffmpegPercent -Status ("Video is {0:N2}% completed..." -f $ffmpegPercent)
                }
            }Until ($ffmpeg.HasExited)
        }
        Else{
            $ffmpeg = Execute-Process -Path $FFMpegPath -Parameters $ffmpegCombinedArgs -CreateNoWindow -PassThru
        }
    }

}

##*===============================================
##* VARIABLE DECLARATION
##*===============================================
[string]$ScriptNameDesc = "Transocde Large Video Files"
[string]$ScriptVersion= "1.0"

[string]$searchDir = 'F:\Media\TV Series'
[int32]$FindSizeGreaterThan = 800MB

[boolean]$UsePlexComSkip = $false
[string]$PythonPath = 'C:\Python27\python.exe'
[string]$PlexDVRComSkipScriptPath = 'E:\Data\Plex\DVRPostProcessingScript\comskip81_098\PlexComskip.py'
[string]$ComSkipPath = 'E:\Data\Plex\DVRPostProcessingScript\comskip82_003'

[string]$FFMpegPath = 'E:\Data\Plex\DVRPostProcessingScript\ffmpeg\bin\ffmpeg.exe'
[string]$FFProbePath = 'E:\Data\Plex\DVRPostProcessingScript\ffmpeg\bin\ffprobe.exe'
[string]$TranscodeDir = 'G:\TranscoderTempDirectory\ComskipInterstitialDirectory'
[string]$TranscodeLogDir = 'E:\Data\Plex\DVRPostProcessingScript\Logs'

[boolean]$Transcode2PassAlways = $false
[int32]$TranscodePasses = 2
[string]$TranscodeJobName = "FFMPEG"

[Boolean]$CheckCommercialSkip = $False
[string]$CommericalJobName = "COMSKIP"

# Get Start Time
$startDTM = (Get-Date)

[string]$global:LogFilePath = "E:\Data\Processors\Logs\$scriptName-$(Get-Date -Format yyyyMMdd).log"

Write-Log -Message ("Script Started [{0}]" -f (Get-Date)) -Source $scriptName -Severity 1 -WriteHost -MsgPrefix (Pad-PrefixOutput -Prefix $scriptName -UpperCase)

Import-Module BitsTransfer
##*===============================================
##* MAIN
##*===============================================
$CheckSize = Convert-ToBytes $FindSizeGreaterThan

Write-Log -Message ("Searching for large video files in [{0}], this may take a while..." -f $searchDir) -Source 'SEARCHER' -Severity 4 -WriteHost -MsgPrefix (Pad-PrefixOutput -Prefix "SEARCHER" -UpperCase) 

#get size of entire directory
$SearchFolderStatsBefore = Get-HugeDirStats $searchDir
#get all files larger than speicifed size and order than by largest first
$FoundLargeFiles = Get-ChildItem $searchDir -Recurse -ErrorAction "SilentlyContinue" | Where-Object {$_.Length -gt $FindSizeGreaterThan} | Sort-Object length -Descending
Write-Log -Message ("Found [{0}] files with size over [{1}], File processing will start soon. DO NOT close any windows that may popup up!" -f [int32]$FoundLargeFiles.Count,$CheckSize) -Source 'SEARCHER' -Severity 2 -WriteHost -MsgPrefix (Pad-PrefixOutput -Prefix "SEARCHER" -UpperCase) 

#get length of current count to format message equally
$FoundFileLength = [int32]$FoundLargeFiles.Count.ToString().Length

$currentCount = 0
$res = @()
#process each file using ffmpeg
Foreach ($file in $FoundLargeFiles){
    $Size = Convert-ToBytes $file.Length
    $currentCount = $currentCount+1
    [string]$PadCurrentCount = Pad-Counter -Number $currentCount -MaxPad $FoundFileLength
    $FileWriteHostPrefix = Pad-PrefixOutput -Prefix ("File {0} of {1}" -f $PadCurrentCount,$FoundLargeFiles.Count) -UpperCase

    #build progress bar for overall process
    $FilePercent = $PadCurrentCount / $FoundLargeFiles.Count * 100
    Write-Progress -id 1 -Activity ("Overall status [{1:N2}%]" -f $FileWriteHostPrefix,$FilePercent) -PercentComplete $FilePercent -Status ("Processing file {0} of {1} : : {2}" -f $PadCurrentCount,$FoundLargeFiles.Count,$file.Name)

    #build working directory
    $GUID = $([guid]::NewGuid().ToString().Trim())
    $ParentDir = Split-path $File.FullName -Parent
    $WorkingDir = Join-Path $TranscodeDir -ChildPath $GUID
    New-Item $WorkingDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    #build new filename and path
    $NewFileName = $file.BaseName + '.mp4'
    $NewFileFullPath = Join-Path $WorkingDir -ChildPath $NewFileName

    #build null filename and path for 2 passes
    $NullFileName = 'null.mp4'
    $NullFileFullPath = Join-Path $WorkingDir -ChildPath $NullFileName

    #get duration of video to calculate progress bar. If durastion is not found, do not display progress bar
    Write-Log -Message ("Probing file [{0}] for duration time" -f $file.Name) -Source $TranscodeJobName -Severity 5 -WriteHost -MsgPrefix $FileWriteHostPrefix 
    $Progress = $false
    $ffprobeDur = Execute-Process -Path $FFProbePath -Parameters "-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 ""$($file.FullName)""" -CreateNoWindow -PassThru
    $totalTime = $ffprobeDur.StdOut
    If($totalTime){$Progress = $true}

    #Treat .ts files differently than others
    #if extension is .ts this means it was recorded by a tuner
    #process it for commercialsand transcode it with 2 passes.
    If($file.Extension -eq '.ts'){
        If($CheckCommercialSkip){
            Write-Log -Message ("Recorded File found [{0}], removing commercials..." -f $file.Name) -Source $CommericalJobName -Severity 5 -WriteHost -MsgPrefix $FileWriteHostPrefix
            If($UsePlexComSkip){
                $comskip = Execute-Process -Path $PythonPath -Parameters "$PlexDVRComSkipScriptPath ""$($file.FullName)""" -CreateNoWindow -PassThru
            }Else{
                $comskip = Execute-Process -Path "$ComSkipPath\comskip.exe" -Parameters "--output ""$WorkingDir"" --ini ""$ComSkipPath\comskip.ini"" ""$($file.FullName)""" -CreateNoWindow -PassThru
            }
            If($comskip.ExitCode -eq 0)
            {
                Write-Log -Message ("Successfully processed commercials from file [{0}]." -f $file.FullName) -Source $CommericalJobName -Severity 0 -WriteHost -MsgPrefix $FileWriteHostPrefix
            }
            Else{
                Write-Log -Message ("Fail to pull commercials from file [{0}]. Error: {1}:{2}" -f $file.FullName,$comskip.ExitCode,$comskip.StdErr) -Source $CommericalJobName -Severity 3 -WriteHost -MsgPrefix $FileWriteHostPrefix
            }
        }Else{
            Write-Log -Message ("Recorded File found [{0}], skipping commercials check..." -f $file.Name) -Source $CommericalJobName -Severity 2 -WriteHost -MsgPrefix $FileWriteHostPrefix
        }

        If($Transcode2PassAlways -and ($File.Length -gt $FindSizeGreaterThan) ){
            #now re-encode the video to reduce it size
            Write-Log -Message ("[{0}] is too large [{1}]. Preparing re-transcoding 2 passes to reduce file size" -f $file.Name,$Size) -Source $TranscodeJobName -Severity 2 -WriteHost -MsgPrefix $FileWriteHostPrefix
            $ffmpegCombinedArgs = "-f mp4 -ac 2 -ar 44100 -threads 4 -c:v libx264 -c:a ac3 -crf 30 -preset fast"
            $ffmpeg = Start-FFMPEGProcess -DisplayProgress $Progress -Passes
        }

    }
    Else {

        #if a time duration was found, a progess bar can be used
        If($Transcode2PassAlways){
            #now re-encode the video to reduce it size
            Write-Log -Message ("[{0}] is too large [{1}]. Preparing re-transcoding 2 passes to reduce file size" -f $file.Name,$Size) -Source $TranscodeJobName -Severity 2 -WriteHost -MsgPrefix $FileWriteHostPrefix

            $ffmpeg = Start-FFMPEGProcess -DisplayProgress $Progress -Passes
        }
        Else{

            #build ffmpeg arguments
            $ffmpegAlwaysUseArgs = "-f mp4 -ac 2 -ar 44100 -threads 4"

            #get video extention to detemine ffmpeg arguments
            switch($file.Extension){
                '.avi'  {$ffmpegExtArgs = '-c:v libx264 -c:a aac -b:a 128k -crf 20 -preset fast'}
                '.mkv'  {$ffmpegExtArgs = '-c:v libx264 -c:a copy -crf 23'}
                '.mp4'  {$ffmpegExtArgs = '-c:v libx264 -crf 20 -preset veryfast -profile:v baseline'}
                '.wmv'  {$ffmpegExtArgs = '-c:v libx264 -c:a aac -crf 23-strict -2 -q:a 100 -preset fast'}
                '.mpeg' {$ffmpegExtArgs = '-c:v libx264 -c:a aac -b:a 128k -crf 20 -preset fast'}
                '.mpg'  {$ffmpegExtArgs = '-c:v copy -c:a ac3 -crf 30 -preset veryfast'}
                '.vob'  {$ffmpegExtArgs = '-c:v mpeg4 -c:a libmp3lame -b:v 800k -g 300 -bf 2  -b:a 128k'}
                default {$ffmpegExtArgs = '-c:v copy -c:a copy -crf 30 -preset veryfast'}
            }

            #Get video resolution to determine ffmpeg argument
            $ffprobeRes = Execute-Process -Path $FFProbePath -Parameters "-v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 ""$($file.FullName)""" -PassThru
            #sometimes videow have mutlple streams with resolutions of the same, we just need one
            $vidres = (($ffprobeRes.StdOut) -split '[\r\n]') | Where-Object {$_} | Select-Object -First 1
            #If any of the resolutiuons exist, add a ffmpeg paramter to reduce it.
            $ffmpegVidArgs = ''
            switch( $vidres ){
                '1920x1080' {$ffmpegVidArgs = '-s 4cif'}
                '1280x720'  {$ffmpegVidArgs = '-s 4cif'}
                '1280x718'  {$ffmpegVidArgs = '-s hd720'}
                '1280x714'  {$ffmpegVidArgs = '-s hd720'}
                '128×96'    {$ffmpegVidArgs = '-vf super2xsai'}
                '256×192'   {$ffmpegVidArgs = '-vf super2xsai'}
            }

            #combine all the parameter to build the main string
            $ffmpegCombinedArgs  = "-y -i ""$($file.FullName)"" $ffmpegAlwaysUseArgs $ffmpegVidArgs $ffmpegExtArgs ""$NewFileFullPath"""
            #$ffmpegCombinedArgs  = "-y -i ""$($file.FullName)"" $ffmpegAlwaysUseArgs $ffmpegVidArgs $ffmpegExtArgs ""$NewFileFullPath"" 2> ""$TranscodeLogDir\$GUID.log"""
            #now re-encode the video to reduce it size
            Write-Log -Message ("[{0}] is too large [{1}]. Preparing re-transcoding process to reduce file size" -f $file.Name,$Size) -Source $TranscodeJobName -Severity 2 -WriteHost -MsgPrefix $FileWriteHostPrefix 

            $ffmpeg = Start-FFMPEGProcess -DisplayProgress $Progress

            $NewFile = Get-Childitem $NewFileFullPath -ErrorAction "SilentlyContinue"
            $NewSize = Convert-ToBytes $NewFile.Length
            $NewFilefProbe = Execute-Process -Path $FFProbePath -Parameters "-v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 ""$NewFileFullPath""" -CreateNoWindow -PassThru
            $NewVidRes = ($NewFilefProbe.StdOut).Trim()

            #Check if size is larger than specified size , if so try to ruyn two pass on it
            If($NewFile.Length -gt $FindSizeGreaterThan){
                Write-Log -Message ("[{0}] is STILL too large [{1}], will try to run 2 passes reduce file size" -f $NewFile.Name,$NewSize) -Source $TranscodeJobName -Severity 2 -WriteHost -MsgPrefix $FileWriteHostPrefix 

                $ffmpeg = Start-FFMPEGProcess -DisplayProgress $Progress -Passes
            }
        }

        #if transocde file is smaller than orginial, concider it an success
        $NewFile = Get-Childitem $NewFileFullPath -ErrorAction "SilentlyContinue"
        $NewSize = Convert-ToBytes $NewFile.Length
        If($NewFile.Length -lt $FindSizeGreaterThan){

            Write-Log -Message ("[{0}] has been reduced to [{1}]" -f $NewFile.Name,$NewSize) -Source $TranscodeJobName -Severity 0 -WriteHost -MsgPrefix $FileWriteHostPrefix

            #move file back to original location
            Write-Log -Message ("Transferring [{0}] to [{1}]" -f $NewFile.FullName,$ParentDir) -Source 'BITS' -Severity 5 -WriteHost -MsgPrefix $FileWriteHostPrefix
            $bits = Start-BitsTransfer -Source "$NewFileFullPath" -Destination $ParentDir -Description "Transferring to $ParentDir" -DisplayName "Moving $NewFileName" -Asynchronous

			While ($bits.JobState -eq "Transferring") {
                Start-Sleep -Seconds 1
            }
 
            If ($bits.InternalErrorCode -ne 0) {
                Write-Log -Message ("Fail to transfer [{0}]. Error: {1}" -f $NewFile.FullName,$bits.InternalErrorCode) -Source 'BITS' -Severity 3 -WriteHost -MsgPrefix $FileWriteHostPrefix  
            } else {
                Write-Log -Message ("Successfully transferred [{0}] to [{1}]" -f $NewFile.FullName,$ParentDir) -Source 'BITS' -Severity $bits.InternalErrorCode -WriteHost -MsgPrefix $FileWriteHostPrefix

                #remove original file
                Write-Log -Message ("Deleting original file [{0}]" -f $File.FullName) -Source 'BITS' -Severity 5 -WriteHost -MsgPrefix $FileWriteHostPrefix
                Remove-Item "$($file.FullName)" -Force -ErrorAction SilentlyContinue | Out-Null

                #Record video information
                [psobject]$vids = New-Object -TypeName 'PSObject' -Property @{
                    OriginalRes  = $vidres
                    OriginalSize = Convert-ToBytes $file.Length
                    OriginalName = $file.Name
                    Filepath = Split-Path $file.FullName -Parent
                    NewName = $NewFileName
                    NewSize = Convert-ToBytes $NewFile.Length
                    NewRes = $NewVidRes
                    GUID = $GUID
                    }
                $res += $vids

            }
        }
        Else{
            Write-Log -Message ("Transcode failed to reduce the file [{0}], size is [{1}]" -f $NewFileFullPath,$NewSize) -Source $TranscodeJobName -Severity 3 -WriteHost -MsgPrefix $FileWriteHostPrefix
            #remove working directory if failed
            Remove-Item $WorkingDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
            Continue
        }
	}
	
    #remove working directory
    Write-Log -Message ("Removing working directory [{0}]" -f $WorkingDir) -Source 'BITS' -Severity 5 -WriteHost -MsgPrefix $FileWriteHostPrefix
    Remove-Item $WorkingDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

}

$SearchFolderStatsAfter = Get-HugeDirStats $searchDir
$shrinkspace = ( ($SearchFolderStatsBefore.Size - $SearchFolderStatsAfter.Size) / 1gb)

# Get End Time
$endDTM = (Get-Date)

$ts =  [timespan]::fromseconds(($endDTM-$startDTM).totalseconds)
Write-Log -Message ("Script Completed on [{0}] in [{1}]. Saved [{2}] in file space" -f (Get-Date),$ts.ToString("hh\:mm\:ss\,fff"),$shrinkspace) -Source $scriptName -Severity 1 -WriteHost -MsgPrefix $scriptName 
return $res