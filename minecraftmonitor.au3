#Region ;**** Directives created by AutoIt3Wrapper_GUI ****
#AutoIt3Wrapper_Change2CUI=y
#EndRegion ;**** Directives created by AutoIt3Wrapper_GUI ****
#include <Constants.au3>

; Defining some variables used later in the script
Local Const $sMaxConnections = 10
Local $ahSocket[$sMaxConnections], $asBuffer[$sMaxConnections], $aiAuth[$sMaxConnections], $asIpAddresses[$sMaxConnections]
Local Const $logFile = "minecraftmonitor.log"

; Reading options
Local $writeToClients = ""
Local Const $cfgFile = "minecraftmonitor.ini"

_LogLine("Starting minecraft monitor")

_LogLine("Reading configuration ..")
If Not FileExists($cfgFile) Then
	_FatalError("minecraftmonitor.ini does not exist.")
EndIf

; General options
Local $java = IniRead($cfgFile, "General", "javaexe", "")
If $java = "" Then _FatalError("minecraftmonitor.ini does not contain non-empty ""javaexe"" key in section General")
Local $javaparams = IniRead($cfgFile, "General", "javaparams", "")
Local $serverjar = IniRead($cfgFile, "General", "serverjar", "")
If $serverjar = "" Then _FatalError("minecraftmonitor.ini does not contain non-empty ""serverjar"" key in section General")
If Not StringInStr($serverjar, "\") Then
	$serverjar = @ScriptDir & "\" & $serverjar
EndIf
Local $jarparams = IniRead($cfgFile, "General", "jarparams", "")

; Options for shutdown
Local $forceKill = Boolean(IniRead($cfgFile, "Shutdown", "ForceKill", false))
Local $gracePeriod = Number(IniRead($cfgFile, "Shutdown", "GracePeriod", 30)) * 1000

; Options for remote administration
Local $sIPAddress = @IPAddress1; TODO: Optionize
Local $nPort = IniRead($cfgFile, "RemoteAdmin", "port", 23)
Local $sAdminPass = IniRead($cfgFile, "RemoteAdmin", "password", "")
If $sAdminPass = "" Then _FatalError("minecraftmonitor.ini does not contain non-empty ""sAdminPass"" key in section RemoteAdmin")

; Options for backup
Local $doBackup = Boolean(IniRead($cfgFile, "Backup", "DoBackup", false))
Local $backupEveryMinutes = IniRead($cfgFile, "Backup", "BackupEveryMinutes", 0)
Local $keepMaxLogs = IniRead($cfgFile, "Backup", "KeepMaxLogs", 0)
Local $inGameWarn10m = IniRead($cfgFile, "Backup", "InGameWarning10m", "")
Local $inGameWarn5m = IniRead($cfgFile, "Backup", "InGameWarning5m", "")
Local $inGameWarn = IniRead($cfgFile, "Backup", "InGameWarning", "")

DirCreate("backup")

; Configuration based on other configurations
Local Const $executable = """" & $java & """ " & $javaparams & " -jar """ & $serverjar & """ " & $jarparams

_LogLine("Configuration read")

; Assume last backup is very recent (TODO: Check real time last backup was made)
Local $lastBackup = TimerInit()

; Setting up remote administration
TCPStartup()

_LogLine("Remote administration listening on " & $sIPAddress & ":" & $nPort)
$sMainSocket = TCPListen($sIPAddress, $nPort, 5)
If @error Then
    Switch @error
        Case 1
            _FatalError("The listening address was incorrect (Possibly another server was already running): " & $sIPAddress)
        Case 2
            _FatalError("The listening port was incorrect (Possibly another server was already running): " & $nPort)
        Case Else
            _FatalError("Unable to set up a listening server on " & $sIPAddress & ":" & $nPort & " with error: " & $sMainSocket & @CRLF & _
						"For more information on this error, go to: http://msdn.microsoft.com/en-us/library/ms740668.aspx")
    EndSwitch
EndIf

; Running the server
_LogLine("Starting server as: " & $executable)
OnAutoItExitRegister("OnExitCloseServer")
$pid = Run($executable, @ScriptDir, @SW_HIDE, $STDIN_CHILD + $STDOUT_CHILD + $STDERR_CHILD)
If @error Then
	_FatalError("Unable to start process with error: " & @error)
EndIf

_LogLine("Server has started succesfully")

While 1
	_CheckBackupTimer()
	_DoNetworkEvents()
WEnd

Func _DoNetworkEvents()
	$writeToClients = ""

	; Accept new incoming clients, and ask them to authorise.
    $hNewSocket = TCPAccept($sMainSocket)
    If $hNewSocket > -1 Then
        For $x = 0 To UBound($ahSocket) - 1
            If Not $ahSocket[$x] Then
                $ahSocket[$x] = $hNewSocket
                $aiAuth[$x] = 0
				$asIpAddresses[$x] = _SocketToIP($hNewSocket)
				_LogLine($asIpAddresses[$x] & " has connected.")
                TCPSend($ahSocket[$x], "Please enter the administrator password" & @CRLF & ">")
                ExitLoop
            EndIf
        Next
    EndIf

	; Read error and output from the application

	; Read errors first
	$errLine = StderrRead($pid)
	If @error Then
		If Not ProcessExists($pid) Then
			$pid = 0
			_Log("Server process has closed. Shutting down server.")
			Exit
		EndIf
	EndIf
	If $errLine <> "" Then
		$errLine = StringReplace($errLine, @LF, @CRLF) ; For Windows standardness, and Windows telnet clients
		_Log($errLine)
	EndIf

	; Read output lines
	$line = StdoutRead($pid)
	If $line <> "" Then
		$line = StringReplace($line, @LF, @CRLF) ; For Windows standardness, and Windows telnet clients
		_Log($line)
	EndIf

    ; Loop through existing connections, check if they sent us any data
    For $x = 0 To UBound($ahSocket) - 1
        If $ahSocket[$x] Then
            ; Handle incoming data
            $sData = TCPRecv($ahSocket[$x], 100)
            $asBuffer[$x] &= $sData
            If @error Then
                TCPCloseSocket($ahSocket[$x])
                $ahSocket[$x] = ""
                $asBuffer[$x] = ""
                $aiAuth[$x] = 0
            ElseIf Asc($sData) = 0x8 Then ;backspace received
                $len = StringLen($asBuffer[$x])
                $asBuffer[$x] = StringTrimRight($asBuffer[$x], 2) ; trim the buffer
                If $len = 1 Then
                    TCPSend($ahSocket[$x], ">")
                Else
                    TCPSend($ahSocket[$x], " " & Chr(0x8))
                EndIf
            EndIf

            ; Handle data, in case data is complete: ended with newline
            If StringInStr($asBuffer[$x], @CRLF) Then
                $asBuffer[$x] = StringTrimRight($asBuffer[$x], 2)
				If StringLen($asBuffer[$x]) = 0 Then
					$asBuffer[$x] = " " ; You cannot send "nothing" over TCP (no packet is sent), thus I replace it with something non obstrusive
				EndIf

                ; Check if user is authorised
                If $aiAuth[$x] == 0 Then
                    ; Not authorised, user is typing password
                    If ($asBuffer[$x] == $sAdminPass) Then
                        $aiAuth[$x] = 1
                        TCPSend($ahSocket[$x], "Administrator authorization granted." & @CRLF & @CRLF)
						_LogLine($asIpAddresses[$x] & " logged in as Administrator.")
                    Else
                        TCPSend($ahSocket[$x], "Access denied." & @CRLF & ">")
                    EndIf
                Else
					; Authorised
					If $asBuffer[$x] <> "" Then
						If StringLeft($asBuffer[$x], 7) = "monitor" Then
							Switch $asBuffer[$x]
								Case "monitor-close"
									_LogLine("Executed command: monitor-close" & $asBuffer[$x], $asIpAddresses[$x])
									Exit
								Case Else
									_LogLine("Unrecognized command: " & $asBuffer[$x], $asIpAddresses[$x])
							EndSwitch
						Else
							_SendCommandToServer($asBuffer[$x], $asIpAddresses[$x])
						EndIf
					EndIf
                EndIf
                $asBuffer[$x] = ""
            EndIf

			If $aiAuth[$x] Then ; no @CRLF in buffer, but user is authed for output
				TCPSend($ahSocket[$x], $writeToClients)
			EndIf
        EndIf
    Next
EndFunc

Func _CheckBackupTimer()
	If Not $doBackup Then Return

	$msLastBackup = TimerDiff($lastBackup)
	If $msLastBackup > $backupEveryMinutes*60*1000 Then
		_DoBackup()
	EndIf
EndFunc

Func _DoBackup()
	$dest = _GetBackupDirName()
	_LogLine("Starting backup..")

	If $inGameWarn <> "" Then
		_SendCommandToServer("say " & $inGameWarn)
	EndIf

	_SendCommandToServer("save-all")

	$start = TimerInit()
	While TimerDiff($start) < 15000
		_DoNetworkEvents()
	WEnd

	_LogLine("Starting directory copy of \world\ to \" & $dest)
	DirCopy("world", $dest, 1)

	$lastBackup = TimerInit()

	_LogLine("Backup completed")
EndFunc

Func _GetBackupDirName()
	If Not FileExists("backup") Then
		DirCreate("backup")
	EndIf
	Return "backup\world " & @YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & "-" & @MIN & "-" & @SEC & "\"
EndFunc

Func _SendCommandToServer($command, $source = "MONITOR")
	StdinWrite($pid, $command & @CRLF)
	_LogLine("Sent command to server: " & $command, $source)
EndFunc

Func OnExitCloseServer()
	_LogLine("Closing .. ")
	If $pid <> 0 AND ProcessExists($pid) Then
		If $forceKill Then
			_LogLine("Forcing close.")
			ProcessClose($pid)
		Else
			$init = TimerInit()
			_SendCommandToServer("stop") ; Send the stop command
			While ProcessExists($pid)
				Sleep(500)
				If TimerDiff($init) > $gracePeriod Then
					_LogLine("Server did not stop after grace period. Forcing close.")
					ProcessClose($pid)
					ExitLoop
				EndIf
			WEnd
		EndIf
	EndIf
	_LogLine("Closed")
EndFunc

Func Boolean($sBool)
	If $sBool = "false" Then
		Return False
	ElseIf $sBool = "" Then
		Return False
	EndIf
	Return True
EndFunc

Func _SocketToIP($SHOCKET)
    Local $sockaddr, $aRet
    $sockaddr = DllStructCreate("short;ushort;uint;char[8]")
    $aRet = DllCall("Ws2_32.dll", "int", "getpeername", "int", $SHOCKET, _
             "ptr",  DllStructGetPtr($sockaddr), "int*", DllStructGetSize($sockaddr))
    If Not @error And $aRet[0] =  0 Then
        $aRet = DllCall("Ws2_32.dll", "str", "inet_ntoa", "int", DllStructGetData($sockaddr, 3))
        If Not @error Then $aRet = $aRet[0]
    Else
        $aRet = 0
    EndIf
    $sockaddr = 0
	Return $aRet
EndFunc

Func _FatalError($msg)
	_Log("[Error] " & $msg & @CRLF)
	Exit
EndFunc

Func _LogLine($msg, $source = "MONITOR")
	_Log(@YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & ":" & @MIN & ":" & @SEC & " [" & $source & "] " & $msg & @CRLF)
EndFunc

Func _Log($msg)
	$writeToClients &= $msg
	FileWrite($logFile, $msg)
	ConsoleWrite($msg)
EndFunc