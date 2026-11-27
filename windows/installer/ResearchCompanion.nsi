Unicode true
RequestExecutionLevel user
Name "Research Companion ${VERSION}"
OutFile "${OUTPUT}"
InstallDir "$LOCALAPPDATA\Programs\Research Companion"
Icon "${ICON}"
UninstallIcon "${ICON}"
SetCompressor /SOLID lzma
SetOverwrite on
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "${FILE_VERSION}"
VIAddVersionKey /LANG=1033 "ProductName" "Research Companion"
VIAddVersionKey /LANG=1033 "FileDescription" "Research Companion Windows x64 Candidate"
VIAddVersionKey /LANG=1033 "FileVersion" "${FILE_VERSION}"
VIAddVersionKey /LANG=1033 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=1033 "LegalCopyright" "Research Companion contributors"

!include "MUI2.nsh"
!include "WinVer.nsh"
!include "x64.nsh"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${LICENSE}"
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"

!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\ResearchCompanionWindows"
Var GuardMutex

!macro RC_Abort message
  MessageBox MB_OK|MB_ICONSTOP "${message}" /SD IDOK
  SetErrorLevel 1
  Abort
!macroend

!macro RC_Begin
  SetShellVarContext current
  StrCpy $INSTDIR "$LOCALAPPDATA\Programs\Research Companion"
  System::Call 'kernel32::CreateMutexW(p0,i1,w "Local\ResearchCompanion.Windows") p .r0 ?e'
  Pop $1
  ${If} $0 == 0
  ${OrIf} $1 == 183
    !insertmacro RC_Abort "Close Research Companion and any other Research Companion installer, then try again. 请先退出科研助手及其他安装程序。"
  ${EndIf}
  StrCpy $GuardMutex $0
!macroend

!macro RC_End
  System::Call 'kernel32::ReleaseMutex(p $GuardMutex)'
  System::Call 'kernel32::CloseHandle(p $GuardMutex)'
!macroend

!macro RC_CheckPath path expected
  System::Call 'kernel32::GetFileAttributesW(w "${path}") i .r2'
  ${If} $2 != -1
    IntOp $3 $2 & 0x410
    ; IntOp stores the result as a decimal string; LogicLib != compares strings.
    ${If} $3 != ${expected}
      !insertmacro RC_Abort "The install path is redirected or has an unexpected type. 安装路径被重定向或类型异常。"
    ${EndIf}
  ${EndIf}
!macroend

!macro RC_CheckManaged prefix suffix
  !insertmacro RC_CheckPath "$INSTDIR${suffix}" 16
  ${If} ${FileExists} "$INSTDIR${suffix}\*.*"
    Push "$INSTDIR${suffix}"
    Call ${prefix}CheckTree
    ClearErrors
    FileOpen $2 "$INSTDIR${suffix}\InstallReceipt.txt" r
    ${If} ${Errors}
      !insertmacro RC_Abort "The destination is not managed by this installer. 当前目录缺少有效的安装收据。"
    ${EndIf}
    FileRead $2 $3
    FileClose $2
    ${If} $3 != "Research Companion per-user payload$\r$\n"
    ${AndIf} $3 != "Research Companion per-user payload$\n"
      !insertmacro RC_Abort "The destination is not managed by this installer. 当前目录缺少有效的安装收据。"
    ${EndIf}
  ${EndIf}
!macroend

; NSIS recursive removal descends into directory reparse points.
!macro RC_DefineCheckTree prefix
Function ${prefix}CheckTree
  Exch $0
  Push $1
  Push $2
  Push $3
  Push $4
  FindFirst $1 $2 "$0\*"
  ${DoWhile} $2 != ""
    ${If} $2 != "."
    ${AndIf} $2 != ".."
      System::Call 'kernel32::GetFileAttributesW(w "$0\$2") i .r3'
      IntOp $4 $3 & 0x400
      ${If} $3 == -1
      ${OrIf} $4 != 0
        FindClose $1
        !insertmacro RC_Abort "The managed payload contains a redirected or inaccessible entry. 程序目录中有重定向或不可读取的项目。"
      ${EndIf}
      IntOp $4 $3 & 0x10
      ${If} $4 == 16
        Push "$0\$2"
        Call ${prefix}CheckTree
      ${EndIf}
    ${EndIf}
    ClearErrors
    FindNext $1 $2
    ${If} ${Errors}
      ${ExitDo}
    ${EndIf}
  ${Loop}
  FindClose $1
  Pop $4
  Pop $3
  Pop $2
  Pop $1
  Pop $0
FunctionEnd
!macroend

!insertmacro RC_DefineCheckTree ""
!insertmacro RC_DefineCheckTree "un."

Function .onInit
  ${IfNot} ${AtLeastWin10}
  ${OrIfNot} ${IsNativeAMD64}
    !insertmacro RC_Abort "This candidate requires Windows 10 or 11 on an x64 processor. 此候选版需要 x64 Windows 10/11。"
  ${EndIf}
  !insertmacro RC_Begin
FunctionEnd

Section "Install"
  !insertmacro RC_CheckPath "$LOCALAPPDATA\Programs" 16
  !insertmacro RC_CheckPath "$INSTDIR" 16
  !insertmacro RC_CheckPath "$INSTDIR\Uninstall.exe" 0
  !insertmacro RC_CheckPath "$SMPROGRAMS\Research Companion.lnk" 0
  !insertmacro RC_CheckManaged "" "\app"
  !insertmacro RC_CheckManaged "" "\app-new"
  !insertmacro RC_CheckManaged "" "\app-old"

  ; Recover the previous copy if a power interruption occurred during promotion.
  ${If} ${FileExists} "$INSTDIR\app-old\InstallReceipt.txt"
    ${IfNot} ${FileExists} "$INSTDIR\app\InstallReceipt.txt"
      ClearErrors
      Rename "$INSTDIR\app-old" "$INSTDIR\app"
      IfErrors restore_failed
    ${Else}
      RMDir /r "$INSTDIR\app-old"
    ${EndIf}
  ${EndIf}
  RMDir /r "$INSTDIR\app-new"

  ClearErrors
  SetOutPath "$INSTDIR\app-new"
  File "${PAYLOAD_RECEIPT}"
  File /r /x InstallReceipt.txt "${PAYLOAD_FILES}"
  IfErrors stage_failed
  SetOutPath "$INSTDIR"
  ClearErrors
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  IfErrors stage_failed

  ${If} ${FileExists} "$INSTDIR\app\InstallReceipt.txt"
    ClearErrors
    Rename "$INSTDIR\app" "$INSTDIR\app-old"
    IfErrors stage_failed
  ${EndIf}
  ClearErrors
  Rename "$INSTDIR\app-new" "$INSTDIR\app"
  IfErrors rollback
  RMDir /r "$INSTDIR\app-old"

  CreateShortCut "$SMPROGRAMS\Research Companion.lnk" "$INSTDIR\app\ResearchCompanion.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "Research Companion"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" '"$INSTDIR\app\ResearchCompanion.exe"'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  !insertmacro RC_End
  Goto installed

rollback:
  ${If} ${FileExists} "$INSTDIR\app-old\InstallReceipt.txt"
    ClearErrors
    Rename "$INSTDIR\app-old" "$INSTDIR\app"
    IfErrors restore_failed
  ${EndIf}
stage_failed:
  SetOutPath "$INSTDIR"
  RMDir /r "$INSTDIR\app-new"
  !insertmacro RC_Abort "The new application could not be installed. 安装未完成，科研数据和配置未修改。"
restore_failed:
  !insertmacro RC_Abort "Could not restore the former application. The previous payload is in app-old. 旧应用保留在 app-old。"
installed:
SectionEnd

Function un.onInit
  !insertmacro RC_Begin
FunctionEnd

Section "Uninstall"
  !insertmacro RC_CheckPath "$LOCALAPPDATA\Programs" 16
  !insertmacro RC_CheckPath "$INSTDIR" 16
  !insertmacro RC_CheckPath "$INSTDIR\Uninstall.exe" 0
  !insertmacro RC_CheckPath "$SMPROGRAMS\Research Companion.lnk" 0
  !insertmacro RC_CheckManaged "un." "\app"
  !insertmacro RC_CheckManaged "un." "\app-new"
  !insertmacro RC_CheckManaged "un." "\app-old"
  Delete "$SMPROGRAMS\Research Companion.lnk"
  RMDir /r "$INSTDIR\app"
  RMDir /r "$INSTDIR\app-new"
  RMDir /r "$INSTDIR\app-old"
  Delete "$INSTDIR\Uninstall.exe"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  RMDir "$INSTDIR"
  !insertmacro RC_End
SectionEnd
