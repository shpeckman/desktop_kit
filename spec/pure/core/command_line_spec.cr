# spec/pure/core/command_line_spec.cr
require "../../spec_helper"

describe DesktopKit::CommandLine do
  it "resolves file arguments against its directory" do
    command_line = DesktopKit::CommandLine.new(["notes.txt", "../b c.md", "/etc/hosts", "file:///tmp/a%20b.txt"], Path["/home/user/work"])
    command_line.arguments.map { |argument| command_line.path(argument) }.should eq [
      Path["/home/user/work/notes.txt"],
      Path["/home/user/b c.md"],
      Path["/etc/hosts"],
      Path["/tmp/a b.txt"],
    ]
  end

  it "keeps a leading tilde literal" do
    DesktopKit::CommandLine.new(Array(String).new, Path["/srv"]).path("~x").should eq Path["/srv/~x"]
  end

  it "defaults to the current directory and a local launch" do
    command_line = DesktopKit::CommandLine.new(["a"])
    command_line.directory.should eq Path[Dir.current]
    command_line.remote?.should be_false
  end
end
