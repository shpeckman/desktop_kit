# spec/gtk/core/command_line_spec.cr
require "../harness"

private class OpenApp < TestApp
  getter opened = [] of Array(Path)

  protected def on_open(files : Array(Path)) : Nil
    @opened << files
    record "open"
    quit
  end
end

private class StatusApp < TestApp
  getter command_lines = [] of Apprt::CommandLine

  protected def on_command_line(command_line : Apprt::CommandLine) : Int32
    @command_lines << command_line
    quit
    3
  end
end

describe "App#on_command_line" do
  before_all { GtkHarness.start }

  it "activates without arguments" do
    app = OpenApp.new
    run_app(app).should eq 0
    app.events.should eq ["startup", "scheme light", "activate", "shutdown"]
    app.opened.should be_empty
  end

  it "opens file arguments by default" do
    app = OpenApp.new
    run_app(app, arguments: ["a.txt", "/tmp/b.txt"]).should eq 0
    app.events.should eq ["startup", "scheme light", "open", "shutdown"]
    app.opened.should eq [[Path[Dir.current, "a.txt"], Path["/tmp/b.txt"]]]
    app.off_thread?.should be_false
  end

  it "returns the exit status the hook returns" do
    app = StatusApp.new
    run_app(app, arguments: ["--flag", "value"]).should eq 3
    command_line = app.command_lines.first
    command_line.arguments.should eq ["--flag", "value"]
    command_line.directory.should eq Path[Dir.current]
    command_line.remote?.should be_false
  end
end
