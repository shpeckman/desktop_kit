# spec/gtk/core/scope_spec.cr
require "../harness"

describe "DesktopKit::Systemd.start_scope" do
  before_all { GtkHarness.start }

  it "raises when the session bus has no service manager" do
    process = Process.new("sleep", ["5"])
    begin
      expect_raises(DesktopKit::GLibError, /ServiceUnknown|systemd1/) do
        DesktopKit::Systemd.start_scope(process.pid, "app-desktop-kit-spec-transient-#{process.pid}.scope")
      end
    ensure
      process.terminate
      process.wait
    end
  end
end
