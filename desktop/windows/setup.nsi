Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"
Name "Yapinplugger"
OutFile "${OUTPUT}"
InstallDir "$LOCALAPPDATA\Programs\Yapinplugger"
InstallDirRegKey HKCU "Software\Yapinplugger" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 32
VIProductVersion "1.1.0.0"
VIAddVersionKey "ProductName" "Yapinplugger"
VIAddVersionKey "FileDescription" "Yapinplugger community Yapper client setup"
VIAddVersionKey "FileVersion" "1.1.0"
VIAddVersionKey "LegalCopyright" "Upstream components retain their original ownership."
!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\Yapinplugger.exe"
!define MUI_FINISHPAGE_RUN_NOTCHECKED
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "This package requires 64-bit Windows."
    Abort
  ${EndIf}
FunctionEnd

Section "Yapinplugger client" SEC_CLIENT
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File /r "${APPDIR}/*"
  WriteUninstaller "$INSTDIR\Uninstall Yapinplugger.exe"
  WriteRegStr HKCU "Software\Yapinplugger" "InstallLocation" "$INSTDIR"
  CreateDirectory "$SMPROGRAMS\Yapinplugger"
  CreateShortcut "$SMPROGRAMS\Yapinplugger\Yapinplugger.lnk" "$INSTDIR\Yapinplugger.exe"
  WriteRegStr HKCU "Software\Classes\yapper" "" "URL:Yapper Protocol"
  WriteRegStr HKCU "Software\Classes\yapper" "URL Protocol" ""
  WriteRegStr HKCU "Software\Classes\yapper\DefaultIcon" "" '$\"$INSTDIR\Yapinplugger.exe$\",0'
  WriteRegStr HKCU "Software\Classes\yapper\shell\open\command" "" '$\"$INSTDIR\Yapinplugger.exe$\" $\"%1$\"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Yapinplugger" "DisplayName" "Yapinplugger"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Yapinplugger" "DisplayVersion" "1.1.0"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Yapinplugger" "DisplayIcon" "$INSTDIR\Yapinplugger.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Yapinplugger" "UninstallString" '$\"$INSTDIR\Uninstall Yapinplugger.exe$\"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Yapinplugger" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Yapinplugger" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  ; Electron uses this application name for its optional per-user login item.
  ReadRegStr $1 HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Yapinplugger"
  StrCmp $1 '$\"$INSTDIR\Yapinplugger.exe$\"' remove_login
  StrCmp $1 '$\"$INSTDIR\Yapinplugger.exe$\" --hidden' remove_login keep_login
  remove_login:
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Yapinplugger"
  keep_login:
  ; Remove protocol registration only if this install still owns it.
  ReadRegStr $0 HKCU "Software\Classes\yapper\shell\open\command" ""
  StrCmp $0 '$\"$INSTDIR\Yapinplugger.exe$\" $\"%1$\"' 0 +2
    DeleteRegKey HKCU "Software\Classes\yapper"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Yapinplugger"
  DeleteRegKey HKCU "Software\Yapinplugger"
  Delete "$SMPROGRAMS\Yapinplugger\Yapinplugger.lnk"
  RMDir "$SMPROGRAMS\Yapinplugger"
  ; The manifest limits deletion to installed package files. User profiles stay intact.
  !include "${UNINSTALL_MANIFEST}"
  Delete "$INSTDIR\Uninstall Yapinplugger.exe"
  RMDir "$INSTDIR"
SectionEnd
