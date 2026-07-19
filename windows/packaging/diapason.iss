; Inno Setup script that wraps an already-built Flutter Windows release bundle
; into a .exe installer. The bundle dir, version, arch and output paths are
; passed in from CI with /D defines, e.g.:
;
;   iscc /DMyAppVersion=0.10.0 /DMyArch=x64 ^
;        /DMySourceDir=build\windows\x64\runner\Release ^
;        /DMyOutputDir=installers ^
;        /DMyOutputBaseFilename=diapason-0.10.0_win_x64 ^
;        windows\packaging\diapason.iss
;
; Requires Inno Setup 6.3+ for the arm64 architecture identifiers.

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef MyArch
  #define MyArch "x64"
#endif
#ifndef MySourceDir
  #define MySourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef MyOutputDir
  #define MyOutputDir "installers"
#endif
#ifndef MyOutputBaseFilename
  #define MyOutputBaseFilename "diapason-setup"
#endif

#define MyAppName "Diapason"
#define MyAppPublisher "Nytuo"
#define MyAppURL "https://github.com/Nytuo/diapason"
#define MyAppExeName "diapason.exe"

[Setup]
; Keep this AppId stable across releases so upgrades replace, not duplicate.
AppId={{6F3A9E2C-1B4D-4E7A-9C21-7D5A0B8E4F10}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
DisableProgramGroupPage=yes
OutputDir={#MyOutputDir}
OutputBaseFilename={#MyOutputBaseFilename}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
#if MyArch == "aarch64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
