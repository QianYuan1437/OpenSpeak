; Inno Setup script for OpenSpeak (built in CI: ISCC /DAppVersion=x.y.z)
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6F0B8C9E-3E2A-4C55-9B4D-0E4A3C6D7A11}
AppName=OpenSpeak
AppVersion={#AppVersion}
AppPublisher=QianYuan1437
AppPublisherURL=https://github.com/QianYuan1437/OpenSpeak
DefaultDirName={autopf}\OpenSpeak
DefaultGroupName=OpenSpeak
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputBaseFilename=OpenSpeak-{#AppVersion}-windows-x64-setup
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\openspeak.exe
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "autostart"; Description: "Start OpenSpeak when I sign in / 开机自动启动"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\OpenSpeak"; Filename: "{app}\openspeak.exe"
Name: "{autodesktop}\OpenSpeak"; Filename: "{app}\openspeak.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "OpenSpeak"; ValueData: """{app}\openspeak.exe"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\openspeak.exe"; Description: "{cm:LaunchProgram,OpenSpeak}"; Flags: nowait postinstall skipifsilent
