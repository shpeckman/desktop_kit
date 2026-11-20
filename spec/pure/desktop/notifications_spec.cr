# spec/pure/desktop/notifications_spec.cr
require "../../spec_helper"

private def notifications(limit = 3) : DesktopKit::Notifications
  DesktopKit::Notifications.new(Pointer(Void).null, 1_u64, limit)
end

describe DesktopKit::Notifications do
  it "keeps notifications oldest first" do
    list = notifications
    list.track(1)
    list.track(2)
    list.keys.should eq [1, 2]
  end

  it "moves a notification sent again to the end" do
    list = notifications
    {1, 2, 3, 1}.each { |key| list.track(key.to_u64) }
    list.keys.should eq [2, 3, 1]
  end

  it "drops the oldest notifications at the limit" do
    list = notifications(limit: 2)
    {1, 2, 3, 4}.each { |key| list.track(key.to_u64) }
    list.keys.should eq [3, 4]
  end

  it "forgets all notifications on clear" do
    list = notifications
    {1, 2}.each { |key| list.track(key.to_u64) }
    list.clear
    list.keys.should be_empty
  end
end
