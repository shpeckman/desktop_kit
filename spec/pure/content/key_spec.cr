# spec/pure/content/key_spec.cr
require "../../spec_helper"

describe DesktopKit::Key do
  it "maps X11 keycodes to physical keys" do
    {
       9_u32 => DesktopKit::Key::Escape,
      38_u32 => DesktopKit::Key::KeyA,
      50_u32 => DesktopKit::Key::ShiftLeft,
    }.each do |keycode, key|
      DesktopKit::Key.from_keycode(keycode).should eq key
    end
  end

  it "maps unknown keycodes to Unidentified" do
    DesktopKit::Key.from_keycode(0_u32).should eq DesktopKit::Key::Unidentified
    DesktopKit::Key.from_keycode(7_u32).should eq DesktopKit::Key::Unidentified
    DesktopKit::Key.from_keycode(100_000_u32).should eq DesktopKit::Key::Unidentified
  end
end
