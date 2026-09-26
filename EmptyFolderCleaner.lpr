program EmptyFolderCleaner;

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, MainForm;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Empty Folder Cleaner';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, FormMain);
  Application.Run;
end.
