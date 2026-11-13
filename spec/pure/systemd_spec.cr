# spec/pure/systemd_spec.cr
require "../spec_helper"

describe Apprt::Systemd do
  it "sends a state to NOTIFY_SOCKET" do
    with_notify_socket do |socket|
      Apprt::Systemd.notify("STATUS=Indexing").should be_true
      notifications(socket).should eq ["STATUS=Indexing"]
    end
  end

  it "returns false without NOTIFY_SOCKET" do
    with_env("NOTIFY_SOCKET", nil) do
      Apprt::Systemd.notify("READY=1").should be_false
    end
  end

  it "warns about a NOTIFY_SOCKET that is neither a path nor abstract" do
    with_env("NOTIFY_SOCKET", "relative/notify.sock") do
      Log.capture("apprt") do |logs|
        Apprt::Systemd.notify("READY=1").should be_false
        logs.check(:warn, /neither a path nor an abstract socket/)
      end
    end
  end

  it "warns when nothing listens on NOTIFY_SOCKET" do
    with_env("NOTIFY_SOCKET", File.tempname("apprt-missing", ".sock")) do
      Log.capture("apprt") do |logs|
        Apprt::Systemd.notify("READY=1").should be_false
        logs.check(:warn, /\Asystemd notify: /)
      end
    end
  end
end
