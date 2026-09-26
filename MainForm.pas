unit MainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ComCtrls,
  ExtCtrls, CheckLst, LCLIntf, LCLType;

type
  { Background thread: recursively finds all folders without files.
    The thread never touches the UI; it only fills its own list.
    The form polls for completion with a timer. }
  TScanThread = class(TThread)
  private
    FRoot: string;
    FFound: TStringList;
    FErrorMsg: string;
    function ScanDir(const Dir: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const ARoot: string);
    destructor Destroy; override;
    property Found: TStringList read FFound;
    { Non-empty if the scan ended early because of an error. }
    property ErrorMsg: string read FErrorMsg;
  end;

  TMainForm = class(TForm)
    TopPanel: TPanel;
    LabelStart: TLabel;
    EditPath: TEdit;
    BtnBrowse: TButton;
    BtnAbout: TButton;
    Progress: TProgressBar;
    ListEmpty: TCheckListBox;
    BottomPanel: TPanel;
    LabelStatus: TLabel;
    BtnScan: TButton;
    BtnCancel: TButton;
    BtnSelectAll: TButton;
    BtnClearSel: TButton;
    BtnOpen: TButton;
    ChkRecycle: TCheckBox;
    BtnDelete: TButton;
    procedure FormCreate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormDestroy(Sender: TObject);
    procedure BtnBrowseClick(Sender: TObject);
    procedure BtnAboutClick(Sender: TObject);
    procedure BtnScanClick(Sender: TObject);
    procedure BtnCancelClick(Sender: TObject);
    procedure BtnSelectAllClick(Sender: TObject);
    procedure BtnClearSelClick(Sender: TObject);
    procedure BtnOpenClick(Sender: TObject);
    procedure BtnDeleteClick(Sender: TObject);
    procedure ListEmptyDblClick(Sender: TObject);
    procedure TimerPollTimer(Sender: TObject);
  private
    FResults: TStringList;
    FScanThread: TScanThread;
    FCancelled: Boolean;
    FDeleting: Boolean;
    FCloseRequested: Boolean;
    TimerPoll: TTimer;
    procedure SetBusy(ABusy: Boolean);
    procedure FillList(Items: TStrings; ACheckAll: Boolean);
    procedure AboutLinkClicked(Sender: TObject);
  public
  end;

var
  { Do not name this "MainForm": sharing the unit's name causes
    "Duplicate identifier" in FPC or hides the variable in the .lpr. }
  FormMain: TMainForm;

implementation

{$R *.lfm}

{ Deliberately without the "Windows" unit: it hides SysUtils.FindClose,
  among others (FindClose(SR) would no longer compile). }
uses
  LazUTF8;

const
  FILE_ATTRIBUTE_REPARSE_POINT = $00000400;

  FO_DELETE          = $0003;
  FOF_SILENT         = $0004;
  FOF_NOCONFIRMATION = $0010;
  FOF_ALLOWUNDO      = $0040;
  FOF_NOERRORUI      = $0400;

  { Classic path limit incl. NUL; SHFileOperationW cannot go beyond it. }
  WIN_MAX_PATH = 260;
  { From this length on, file APIs get the \\?\ prefix (leaves room for '\*'
    and the 248-character limit for directories). }
  LONG_PATH_THRESHOLD = 240;

  { Maximum number of folders listed individually in the error dialog. }
  MAX_ERRORS_SHOWN = 20;

  { For a new release, also update the version info in EmptyFolderCleaner.lpi
    (Major/Minor/RevisionNr, ProductVersion). }
  APP_VERSION = '0.2.0';
  APP_AUTHOR  = 'mogeldev';
  APP_URL     = 'https://mogeldev.github.io/';

type
  { Excerpt from the Windows API (shellapi.h), declared here so that no
    third-party unit version matters. shellapi.h uses byte packing on
    32-bit (pshpack1) and natural alignment on 64-bit.
    Expected size: 30 bytes (Win32) or 56 bytes (Win64). }
  {$IFDEF WIN64}
    {$PACKRECORDS C}
  {$ELSE}
    {$PACKRECORDS 1}
  {$ENDIF}
  TSHFileOpStructW = record
    Wnd: PtrUInt;                    { HWND }
    wFunc: LongWord;                 { UINT }
    pFrom: PWideChar;
    pTo: PWideChar;
    fFlags: Word;
    fAnyOperationsAborted: LongBool; { BOOL }
    hNameMappings: Pointer;
    lpszProgressTitle: PWideChar;
  end;
  PSHFileOpStructW = ^TSHFileOpStructW;
  {$PACKRECORDS NORMAL}

function SHFileOperationW(const lpFileOp: PSHFileOpStructW): Integer; stdcall;
  external 'shell32.dll' name 'SHFileOperationW';

{ ----------------------------------------------------------------- Helpers }

{ Prefixes long paths with \\?\ so file APIs work beyond MAX_PATH (the only
  way on Windows 7). Expects an absolute, normalized path (see
  ExpandFileName). }
function LongPath(const APath: string): string;
begin
  if (Length(APath) < LONG_PATH_THRESHOLD) or (Copy(APath, 1, 4) = '\\?\') then
    Result := APath
  else if Copy(APath, 1, 2) = '\\' then
    Result := '\\?\UNC\' + Copy(APath, 3, MaxInt)
  else
    Result := '\\?\' + APath;
end;

{ True for "C:\" or "\\server\share". }
function IsDriveRoot(const APath: string): Boolean;
begin
  Result := SameText(IncludeTrailingPathDelimiter(APath),
    IncludeTrailingPathDelimiter(ExtractFileDrive(APath)));
end;

{ True if Child equals Parent or lies inside it. Both absolute. }
function IsSameOrInside(const Child, Parent: string): Boolean;
var
  C, P: string;
begin
  C := UTF8UpperCase(IncludeTrailingPathDelimiter(Child));
  P := UTF8UpperCase(IncludeTrailingPathDelimiter(Parent));
  Result := Copy(C, 1, Length(P)) = P;
end;

{ Returns the drive root or system folder that Root contains or lies in,
  otherwise ''. Windows or installed programs sometimes expect empty
  folders there. }
function FindProtectedDir(const Root: string): string;
const
  EnvVars: array[0..6] of string = ('SystemRoot', 'ProgramFiles',
    'ProgramFiles(x86)', 'ProgramW6432', 'ProgramData', 'APPDATA',
    'LOCALAPPDATA');
var
  I: Integer;
  Dir: string;
begin
  Result := '';
  if IsDriveRoot(Root) then
    Exit(Root);
  for I := Low(EnvVars) to High(EnvVars) do
  begin
    Dir := GetEnvironmentVariableUTF8(EnvVars[I]);
    if Dir = '' then
      Continue;
    Dir := ExcludeTrailingPathDelimiter(Dir);
    if IsSameOrInside(Root, Dir) or IsSameOrInside(Dir, Root) then
      Exit(Dir);
  end;
end;

{ Messages via the native Windows message box, so the buttons follow the
  Windows display language. Do not use Application.MessageBox: it routes
  to LCL's own dialog (MessageDlg) with LCL's button captions. }
procedure ShowMsg(const ACaption, AText: string; AIcon: LongInt);
begin
  LCLIntf.MessageBox(Application.MainFormHandle, PChar(AText), PChar(ACaption),
    MB_OK or AIcon);
end;

function AskYesNo(const ACaption, AText: string; ADefaultNo: Boolean): Boolean;
var
  Flags: LongInt;
begin
  Flags := MB_YESNO or MB_ICONWARNING;
  if ADefaultNo then
    Flags := Flags or MB_DEFBUTTON2;
  Result := LCLIntf.MessageBox(Application.MainFormHandle, PChar(AText),
    PChar(ACaption), Flags) = IDYES;
end;

{ Checks whether a folder really has no entries left. }
function IsDirReallyEmpty(const Dir: string): Boolean;
var
  SR: TSearchRec;
begin
  Result := True;
  if FindFirst(LongPath(IncludeTrailingPathDelimiter(Dir) + '*'), faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') then
        begin
          Result := False;
          Break;
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end
  else
    Result := False;
end;

{ Text for a SHFileOperationW return value. The DE_* values date back to
  Win16 and are not Win32 error codes. }
function ShellOpErrorText(Code: Integer): string;
begin
  case Code of
    $71..$88, $B7, $402, $10000, $10074:
      Result := Format('Shell error $%x', [Code]);
  else
    Result := Trim(SysErrorMessage(Code));
  end;
end;

{ Moves an (empty) folder to the Recycle Bin.
  On drives without a Recycle Bin (network drives, some USB media) Windows
  deletes permanently without asking because of FOF_NOCONFIRMATION; for
  empty folders nothing is lost. }
function DeleteToRecycleBin(const APath: string; out ErrorText: string): Boolean;
var
  Op: TSHFileOpStructW;
  From: UnicodeString;
  Code: Integer;
begin
  Result := False;
  ErrorText := '';
  From := UnicodeString(APath);
  { SHFileOperationW does not support \\?\ and therefore no long paths. }
  if Length(From) >= WIN_MAX_PATH then
  begin
    ErrorText := 'Path too long for the Recycle Bin';
    Exit;
  end;
  { SHFileOperationW expects a double-NUL-terminated list. }
  From := From + #0;
  FillChar(Op, SizeOf(Op), 0);
  Op.wFunc := FO_DELETE;
  Op.pFrom := PWideChar(From);
  Op.pTo := nil;
  Op.fFlags := Word(FOF_ALLOWUNDO or FOF_NOCONFIRMATION or FOF_SILENT or FOF_NOERRORUI);
  Code := SHFileOperationW(@Op);
  if Code <> 0 then
    ErrorText := ShellOpErrorText(Code)
  else if Op.fAnyOperationsAborted then
    ErrorText := 'Operation aborted'
  else
    Result := True;
end;

{ Permanently deletes an empty folder. RemoveDirectory fails on read-only
  folders with "Access is denied"; in that case clear the attribute and
  retry. If it still fails, the attribute is restored so the folder stays
  unchanged. }
function DeleteDirPermanently(const APath: string; out ErrorText: string): Boolean;
var
  P: string;
  Attr: LongInt;
  Code: Integer;
begin
  ErrorText := '';
  P := LongPath(APath);
  Result := RemoveDir(P);
  if Result then
    Exit;
  Code := GetLastOSError;

  Attr := FileGetAttr(P);
  if (Attr <> -1) and ((Attr and faReadOnly) <> 0) and
     (FileSetAttr(P, Attr and not faReadOnly) = 0) then
  begin
    Result := RemoveDir(P);
    if Result then
      Exit;
    Code := GetLastOSError;
    FileSetAttr(P, Attr);
  end;

  ErrorText := Trim(SysErrorMessage(Code));
end;

{ ------------------------------------------------------------- TScanThread }

constructor TScanThread.Create(const ARoot: string);
begin
  inherited Create(True);       { suspended first, so FFound is ready }
  FreeOnTerminate := False;
  FRoot := ARoot;
  FFound := TStringList.Create;
  Start;
end;

destructor TScanThread.Destroy;
begin
  FFound.Free;
  inherited Destroy;
end;

procedure TScanThread.Execute;
begin
  try
    ScanDir(FRoot);
    { The start folder itself is never offered for deletion. As the
      outermost call it is added last, so if present it is at the end. }
    if (FFound.Count > 0) and (FFound[FFound.Count - 1] = FRoot) then
      FFound.Delete(FFound.Count - 1);
  except
    { The partial result stays valid (every entry was fully checked) but is
      incomplete; the form reports that. }
    on E: Exception do
      FErrorMsg := E.Message;
  else
    FErrorMsg := 'Unknown error';
  end;
end;

{ Returns True if Dir contains no file (recursively).
  Empty folders are added to FFound; children always come before their
  parents, so deletion works "deepest first". }
function TScanThread.ScanDir(const Dir: string): Boolean;
var
  SR: TSearchRec;
  Base: string;
  HasFiles: Boolean;
  AllSubEmpty: Boolean;
begin
  Result := False;
  HasFiles := False;
  AllSubEmpty := True;
  Base := IncludeTrailingPathDelimiter(Dir);

  if FindFirst(LongPath(Base + '*'), faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if Terminated then
          Exit;
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;

        if (SR.Attr and faDirectory) <> 0 then
        begin
          { Do not follow links and do not count them as empty. }
          if (SR.Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
            AllSubEmpty := False
          else if not ScanDir(Base + SR.Name) then
            AllSubEmpty := False;
        end
        else
          HasFiles := True;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end
  else
  begin
    { Not readable -> treat as "not empty" to be safe. }
    HasFiles := True;
  end;

  Result := (not HasFiles) and AllSubEmpty;
  if Result then
    FFound.Add(Dir);
end;

{ --------------------------------------------------------------- TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  FResults := TStringList.Create;
  FScanThread := nil;
  FCancelled := False;
  FDeleting := False;
  FCloseRequested := False;

  TimerPoll := TTimer.Create(Self);
  TimerPoll.Interval := 150;
  TimerPoll.Enabled := False;
  TimerPoll.OnTimer := @TimerPollTimer;

  FillList(nil, False);
  SetBusy(False);
  LabelStatus.Caption := 'Please choose a start folder.';
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  { Deleting calls ProcessMessages; closing in the middle of it would
    destroy the form under the running loop. Cancel instead and close
    afterwards. }
  CanClose := not FDeleting;
  if FDeleting then
  begin
    FCancelled := True;
    FCloseRequested := True;
    LabelStatus.Caption := 'Cancelling deletion…';
  end;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  TimerPoll.Enabled := False;
  if FScanThread <> nil then
  begin
    FScanThread.Terminate;
    FScanThread.WaitFor;
    FreeAndNil(FScanThread);
  end;
  FreeAndNil(FResults);
end;

procedure TMainForm.SetBusy(ABusy: Boolean);
begin
  BtnScan.Enabled := not ABusy;
  BtnCancel.Enabled := ABusy;
  BtnDelete.Enabled := not ABusy;
  BtnBrowse.Enabled := not ABusy;
  EditPath.Enabled := not ABusy;
  BtnSelectAll.Enabled := not ABusy;
  BtnClearSel.Enabled := not ABusy;
  BtnOpen.Enabled := not ABusy;
  ChkRecycle.Enabled := not ABusy;
  ListEmpty.Enabled := not ABusy;

  if ABusy then
  begin
    Progress.Style := pbstMarquee;
    { Arrow with hourglass: busy, but "Cancel" stays usable. }
    Screen.Cursor := crAppStart;
  end
  else
  begin
    Progress.Style := pbstNormal;
    Progress.Position := 0;
    Screen.Cursor := crDefault;
  end;
end;

procedure TMainForm.FillList(Items: TStrings; ACheckAll: Boolean);
var
  I: Integer;
begin
  ListEmpty.Items.BeginUpdate;
  try
    ListEmpty.Items.Clear;
    if Items <> nil then
      for I := 0 to Items.Count - 1 do
        ListEmpty.Items.Add(Items[I]);
    for I := 0 to ListEmpty.Count - 1 do
      ListEmpty.Checked[I] := ACheckAll;
  finally
    ListEmpty.Items.EndUpdate;
  end;
end;

procedure TMainForm.BtnBrowseClick(Sender: TObject);
var
  Dlg: TSelectDirectoryDialog;
begin
  Dlg := TSelectDirectoryDialog.Create(Self);
  try
    Dlg.Title := 'Select start folder';
    if DirectoryExists(Trim(EditPath.Text)) then
      Dlg.InitialDir := Trim(EditPath.Text);
    if Dlg.Execute then
      EditPath.Text := Dlg.FileName;
  finally
    Dlg.Free;
  end;
end;

{ Native TaskDialog (Vista and later): clickable link, OK button in the
  Windows display language. }
procedure TMainForm.BtnAboutClick(Sender: TObject);
var
  Dlg: TTaskDialog;
begin
  Dlg := TTaskDialog.Create(Self);
  try
    Dlg.Caption := 'About';
    Dlg.Title := 'Empty Folder Cleaner';
    Dlg.Text := 'Version ' + APP_VERSION + sLineBreak + sLineBreak +
      'by ' + APP_AUTHOR + sLineBreak +
      '<a href="' + APP_URL + '">' + APP_URL + '</a>';
    Dlg.MainIcon := tdiInformation;
    Dlg.CommonButtons := [tcbOk];
    Dlg.Flags := [tfAllowDialogCancellation, tfEnableHyperlinks,
      tfPositionRelativeToWindow];
    Dlg.OnHyperlinkClicked := @AboutLinkClicked;
    Dlg.Execute;
  finally
    Dlg.Free;
  end;
end;

procedure TMainForm.AboutLinkClicked(Sender: TObject);
begin
  { Deliberately open the constant rather than the URL reported by the dialog. }
  OpenURL(APP_URL);
end;

procedure TMainForm.BtnScanClick(Sender: TObject);
var
  Root, Prot: string;
begin
  Root := Trim(EditPath.Text);
  if Root = '' then
  begin
    ShowMsg('No folder', 'Please select a start folder first.',
      MB_ICONINFORMATION);
    Exit;
  end;

  { Absolute, normalized path: FOF_ALLOWUNDO needs full paths (otherwise the
    folder is deleted permanently), and the working directory must not
    matter between scanning and deleting. }
  Root := ExpandFileName(Root);
  if not IsDriveRoot(Root) then
    Root := ExcludeTrailingPathDelimiter(Root);

  if not DirectoryExists(LongPath(Root)) then
  begin
    ShowMsg('Folder not found',
      'The folder does not exist:' + sLineBreak + Root, MB_ICONWARNING);
    Exit;
  end;
  EditPath.Text := Root;

  Prot := FindProtectedDir(Root);
  if (Prot <> '') and not AskYesNo('System area',
    'The start folder is, contains or lies within a drive root or ' +
    'system folder:' + sLineBreak + Prot + sLineBreak + sLineBreak +
    'Windows or installed programs sometimes expect empty folders there; ' +
    'deleting them can cause problems.' + sLineBreak + sLineBreak +
    'Scan anyway?', True) then
    Exit;

  FResults.Clear;
  FillList(nil, False);
  FCancelled := False;
  SetBusy(True);
  LabelStatus.Caption := 'Scanning…';

  FScanThread := TScanThread.Create(Root);
  TimerPoll.Enabled := True;
end;

procedure TMainForm.BtnCancelClick(Sender: TObject);
begin
  if FDeleting then
  begin
    FCancelled := True;
    LabelStatus.Caption := 'Cancelling deletion…';
  end
  else if FScanThread <> nil then
  begin
    FCancelled := True;
    FScanThread.Terminate;
    LabelStatus.Caption := 'Cancelling scan…';
  end;
end;

procedure TMainForm.TimerPollTimer(Sender: TObject);
var
  Th: TScanThread;
begin
  if (FScanThread = nil) or (not FScanThread.Finished) then
    Exit;

  TimerPoll.Enabled := False;
  Th := FScanThread;
  FScanThread := nil;
  try
    { Finished is set shortly before the thread procedure ends; WaitFor
      makes sure it no longer touches the object. }
    Th.WaitFor;

    if FCancelled then
    begin
      FResults.Clear;
      FillList(nil, False);
      LabelStatus.Caption := 'Scan cancelled.';
    end
    else
    begin
      FResults.Assign(Th.Found);
      FillList(FResults, True);
      if Th.ErrorMsg <> '' then
        LabelStatus.Caption := Format('Scan incomplete (%s): %d empty folder(s) found so far.',
          [Th.ErrorMsg, FResults.Count])
      else if FResults.Count = 0 then
        LabelStatus.Caption := 'No empty folders found.'
      else
        LabelStatus.Caption := Format('%d empty folder(s) found (checked = will be deleted).',
          [FResults.Count]);
    end;
  finally
    Th.Free;
    FCancelled := False;
    SetBusy(False);
  end;
end;

procedure TMainForm.BtnSelectAllClick(Sender: TObject);
var
  I: Integer;
begin
  for I := 0 to ListEmpty.Count - 1 do
    ListEmpty.Checked[I] := True;
end;

procedure TMainForm.BtnClearSelClick(Sender: TObject);
var
  I: Integer;
begin
  for I := 0 to ListEmpty.Count - 1 do
    ListEmpty.Checked[I] := False;
end;

procedure TMainForm.BtnOpenClick(Sender: TObject);
begin
  if ListEmpty.ItemIndex >= 0 then
    OpenDocument(ListEmpty.Items[ListEmpty.ItemIndex]);
end;

procedure TMainForm.ListEmptyDblClick(Sender: TObject);
begin
  BtnOpenClick(Sender);
end;

procedure TMainForm.BtnDeleteClick(Sender: TObject);
var
  ToDelete, Errors: TStringList;
  I, N, Deleted, Skipped, Gone: Integer;
  P, Target, Msg, Reason: string;
  ToRecycle, Ok, WasCancelled: Boolean;
  LastUpdate: QWord;
begin
  ToDelete := TStringList.Create;
  Errors := TStringList.Create;
  try
    for I := 0 to ListEmpty.Count - 1 do
      if ListEmpty.Checked[I] then
        ToDelete.Add(ListEmpty.Items[I]);

    if ToDelete.Count = 0 then
    begin
      ShowMsg('Nothing selected', 'No folders are checked.',
        MB_ICONINFORMATION);
      Exit;
    end;

    ToRecycle := ChkRecycle.Checked;
    if ToRecycle then
      Target := 'moved to the Recycle Bin'
    else
      Target := 'permanently deleted';

    Msg := Format('%d empty folder(s) will be %s.%s%sContinue?',
      [ToDelete.Count, Target, sLineBreak, sLineBreak]);
    { For permanent deletion "No" is the default. }
    if not AskYesNo('Confirm deletion', Msg, not ToRecycle) then
      Exit;

    Deleted := 0;
    Skipped := 0;
    Gone := 0;
    FCancelled := False;
    FDeleting := True;
    SetBusy(True);
    { The count is known: determinate progress instead of marquee. }
    Progress.Style := pbstNormal;
    Progress.Max := ToDelete.Count;
    Progress.Position := 0;
    LastUpdate := 0;
    try
      { ToDelete is already sorted "deepest first" (order from the scan). }
      for I := 0 to ToDelete.Count - 1 do
      begin
        { Service the UI roughly every 100 ms so Windows does not mark the
          window as "Not responding" and Cancel takes effect. }
        if GetTickCount64 - LastUpdate >= 100 then
        begin
          Progress.Position := I;
          LabelStatus.Caption := Format('Deleting… %d of %d', [I, ToDelete.Count]);
          Application.ProcessMessages;
          LastUpdate := GetTickCount64;
        end;
        if FCancelled then
          Break;

        P := ToDelete[I];

        if not DirectoryExists(LongPath(P)) then
        begin
          Inc(Gone);
          Continue;
        end;

        if not IsDirReallyEmpty(P) then
        begin
          Inc(Skipped);
          Continue;
        end;

        if ToRecycle then
          Ok := DeleteToRecycleBin(P, Reason)
        else
          Ok := DeleteDirPermanently(P, Reason);
        if Ok then
          Inc(Deleted)
        else
          Errors.Add(P + '  –  ' + Reason);
      end;

      { Clean up the list: keep only entries that still exist. }
      FResults.Clear;
      for I := 0 to ListEmpty.Count - 1 do
        if DirectoryExists(LongPath(ListEmpty.Items[I])) then
          FResults.Add(ListEmpty.Items[I]);
      FillList(FResults, False);
    finally
      FDeleting := False;
      SetBusy(False);
    end;

    WasCancelled := FCancelled;
    FCancelled := False;
    Msg := Format('%d deleted, %d skipped (no longer empty), %d already gone, %d error(s).',
      [Deleted, Skipped, Gone, Errors.Count]);
    if WasCancelled then
      Msg := 'Cancelled – ' + Msg;
    LabelStatus.Caption := Msg;

    if Errors.Count > 0 then
    begin
      N := Errors.Count;
      if N > MAX_ERRORS_SHOWN then
        N := MAX_ERRORS_SHOWN;
      Msg := 'The following folders could not be deleted:' + sLineBreak;
      for I := 0 to N - 1 do
        Msg := Msg + sLineBreak + Errors[I];
      if Errors.Count > N then
        Msg := Msg + sLineBreak + Format('… and %d more', [Errors.Count - N]);
      ShowMsg('Not deleted', Msg, MB_ICONWARNING);
    end;

    if FCloseRequested then
      Close;
  finally
    Errors.Free;
    ToDelete.Free;
  end;
end;

end.
