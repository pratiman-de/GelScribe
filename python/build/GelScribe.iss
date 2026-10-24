; Inno Setup 6 script for the GelScribe installer: installs the whole dist\GelScribe folder that PyInstaller built.
; build-exe.bat runs it after the zip step: ISCC.exe /DMyAppVersion=0.1.1 build\GelScribe.iss, with the version it
; reads from gelscribe\__init__.py. The result is dist\GelScribe-Setup.exe.
; The paths start from {#SourcePath}, the folder of this file (build), so they don't depend on the current folder.
; Needs Inno Setup 6.3 or newer (x64compatible below).

#ifndef MyAppVersion
  ; only when you run this by hand without /DMyAppVersion=...
  #define MyAppVersion "0.0.0"
#endif

; LICENSE is in the repository root (python\build\..\..\) or, in the small "Windows exe build" folder, next to build\
#if FileExists(SourcePath + "..\LICENSE")
  #define LicenseFilePath SourcePath + "..\LICENSE"
#elif FileExists(SourcePath + "..\..\LICENSE")
  #define LicenseFilePath SourcePath + "..\..\LICENSE"
#else
  #error LICENSE not found in the folder above build or the one above that.
#endif

[Setup]
; Fixed: this is what lets a newer GelScribe-Setup.exe update an installed GelScribe. Never change it.
AppId={{E645BAE3-E45F-44BB-BF75-15AE61B7A76B}
AppName=GelScribe
AppVersion={#MyAppVersion}
AppVerName=GelScribe {#MyAppVersion}
AppPublisher=Pratiman De
DefaultDirName={autopf}\GelScribe
DefaultGroupName=GelScribe
DisableProgramGroupPage=yes
; admin rights are optional: the dialog offers "for me only" (no admin) or "for all users"
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile={#LicenseFilePath}
SetupIconFile={#SourcePath}..\gelscribe\app\resources\icon.ico
UninstallDisplayIcon={app}\GelScribe.exe
OutputDir={#SourcePath}..\dist
OutputBaseFilename=GelScribe-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourcePath}..\dist\GelScribe\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#LicenseFilePath}"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\GelScribe"; Filename: "{app}\GelScribe.exe"
Name: "{autodesktop}\GelScribe"; Filename: "{app}\GelScribe.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\GelScribe.exe"; Description: "{cm:LaunchProgram,GelScribe}"; Flags: nowait postinstall skipifsilent
