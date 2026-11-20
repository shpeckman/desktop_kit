# spec/gtk/desktop/open_url_spec.cr
require "file_utils"
require "./fake_portal"

# Puts a fake `xdg-open` first on PATH while the block runs; it appends its
# argument to the log whose path the block receives, then exits with
# *status* after printing *error* on standard error.
private def with_xdg_open(status : Int32 = 0, error : String = "", & : String ->) : Nil
  dir = File.tempname("desktop-kit-xdg-open")
  Dir.mkdir(dir)
  log = File.join(dir, "opened")
  script = File.join(dir, "xdg-open")
  File.write(script, "#!/bin/sh\nprintf '%s\\n' \"$1\" >> '#{log}'\nprintf '%s' '#{error}' >&2\nexit #{status}\n")
  File.chmod(script, 0o755)
  path = ENV["PATH"]?
  ENV["PATH"] = [dir, path].compact.join(':')
  begin
    yield log
  ensure
    ENV["PATH"] = path
    FileUtils.rm_rf(dir)
  end
end

# Returns the URLs the fake `xdg-open` received, sorted.
private def xdg_opened(log : String) : Array(String)
  File.exists?(log) ? File.read_lines(log).sort! : [] of String
end

# Performs `OpenUrl` for each of *urls* from a window of a new app.
private def open_urls(urls : Array(String)) : Nil
  app = TestApp.new
  run_steps(app) do
    window = app.new_window
    urls.each { |url| trigger(window, DesktopKit::Action::OpenUrl.new(url: url)) }
  end
end

# Runs the block with SIGCHLD reset to the default disposition, as an
# application that waits for its own children might.
private def with_default_sigchld(&) : Nil
  LibC.sigaction(LibC::SIGCHLD, nil, out saved)
  default = LibC::Sigaction.new
  default.sa_sigaction = LibC::SigactionHandlerT.new(Pointer(Void).null, Pointer(Void).null)
  LibC.sigaction(LibC::SIGCHLD, pointerof(default), nil)
  begin
    yield
  ensure
    LibC.sigaction(LibC::SIGCHLD, pointerof(saved), nil)
  end
end

# Opens a URL with a failing `xdg-open` and checks that its error output
# is logged.
private def check_failing_xdg_open : Nil
  with_xdg_open(status: 3, error: "no handler") do |log|
    Log.capture("desktop_kit") do |logs|
      app = TestApp.new
      logged = false
      run_steps(app) do
        trigger(app.new_window, DesktopKit::Action::OpenUrl.new(url: "/tmp/c.txt"))
        logged = eventually { logs.@entries.any?(&.message.==("xdg-open /tmp/c.txt: no handler")) }
      end
      logged.should be_true
      xdg_opened(log).should eq ["/tmp/c.txt"]
    end
  end
end

describe DesktopKit::Action::OpenUrl do
  before_all { GtkHarness.start }

  it "opens a URL through the OpenURI portal" do
    with_xdg_open do |log|
      FakePortal.serve do |portal|
        open_urls(["https://example.com/a"])
        portal.opened.size.should eq 1
        opened = portal.opened.first
        opened.uri.should eq "https://example.com/a"
        opened.ask.should be_false
        opened.writable.should be_false
        opened.activation_token.should_not be_nil
      end
      sleep 200.milliseconds
      xdg_opened(log).should be_empty
    end
  end

  it "falls back to xdg-open when the portal request fails" do
    with_xdg_open do |log|
      FakePortal.serve(response: 2_u32) do |portal|
        open_urls(["https://example.com/b"])
        portal.opened.map(&.uri).should eq ["https://example.com/b"]
      end
      FakePortal.poll { xdg_opened(log) == ["https://example.com/b"] }.should be_true
    end
  end

  it "opens nothing when the user cancels the portal request" do
    with_xdg_open do |log|
      FakePortal.serve(response: 1_u32) do |portal|
        open_urls(["https://example.com/c"])
        portal.opened.map(&.uri).should eq ["https://example.com/c"]
      end
      sleep 200.milliseconds
      xdg_opened(log).should be_empty
    end
  end

  it "opens file URLs and paths with xdg-open" do
    with_xdg_open do |log|
      FakePortal.serve do |portal|
        open_urls(["file:///tmp/a.txt", "/tmp/b.txt"])
        portal.opened.should be_empty
      end
      FakePortal.poll { xdg_opened(log) == ["/tmp/b.txt", "file:///tmp/a.txt"] }.should be_true
    end
  end

  it "logs a failing xdg-open's error output" do
    check_failing_xdg_open
  end

  it "logs a failing xdg-open's error output with SIGCHLD at its default" do
    with_default_sigchld { check_failing_xdg_open }
  end

  it "opens with xdg-open when no portal runs" do
    with_xdg_open do |log|
      open_urls(["https://example.com/d"])
      FakePortal.poll { xdg_opened(log) == ["https://example.com/d"] }.should be_true
    end
  end
end
