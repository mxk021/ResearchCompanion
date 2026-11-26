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

VIProductVersion "${VERSION}.${WINDOWS_BUILD}"
VIAddVersionKey /LANG=1033 "ProductName" "Research Companion"
VIAddVersionKey /LANG=1033 "FileDescription" "Research Companion Windows x64 Candidate"
VIAddVersionKey /LANG=1033 "FileVersion" "${VERSION}.${WINDOWS_BUILD}"
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

!macro RC_CheckDirectory suffix
  System::Call 'kernel32::GetFileAttributesW(w "$INSTDIR${suffix}") i .r2'
  ${If} $2 != -1
    IntOp $3 $2 & 0x410
    ; IntOp stores the result as a decimal string; LogicLib != compares strings.
    ${If} $3 != 16
      !insertmacro RC_Abort "The destination is redirected or is not a directory. 安装目录不是普通目录，未进行修改。"
    ${EndIf}
  ${EndIf}
!macroend

!macro RC_CheckManaged suffix
  !insertmacro RC_CheckDirectory "${suffix}"
  ${If} ${FileExists} "$INSTDIR${suffix}\*.*"
  ${AndIfNot} ${FileExists} "$INSTDIR${suffix}\InstallReceipt.txt"
    !insertmacro RC_Abort "This destination contains files not managed by this installer. 当前目录含有非本安装器管理的文件。"
  ${EndIf}
!macroend

Function .onInit
  ${IfNot} ${AtLeastWin10}
  ${OrIfNot} ${IsNativeAMD64}
    !insertmacro RC_Abort "This candidate requires Windows 10 or 11 on an x64 processor. 此候选版需要 x64 Windows 10/11。"
  ${EndIf}
  !insertmacro RC_Begin
FunctionEnd

Section "Install"
  !insertmacro RC_CheckDirectory ""
  !insertmacro RC_CheckManaged "\app"
  !insertmacro RC_CheckManaged "\app-new"
  !insertmacro RC_CheckManaged "\app-old"

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
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}.${WINDOWS_BUILD}"
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
  !insertmacro RC_CheckDirectory ""
  !insertmacro RC_CheckManaged "\app"
  !insertmacro RC_CheckManaged "\app-new"
  !insertmacro RC_CheckManaged "\app-old"
  Delete "$SMPROGRAMS\Research Companion.lnk"
  RMDir /r "$INSTDIR\app"
  RMDir /r "$INSTDIR\app-new"
  RMDir /r "$INSTDIR\app-old"
  Delete "$INSTDIR\Uninstall.exe"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  RMDir "$INSTDIR"
  !insertmacro RC_End
SectionEnd
