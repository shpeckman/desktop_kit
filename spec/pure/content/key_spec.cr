# spec/pure/content/key_spec.cr
require "../../spec_helper"

describe Apprt::Key do
  it "maps X11 keycodes to physical keys" do
    {
       9_u32 => Apprt::Key::Escape,
      38_u32 => Apprt::Key::KeyA,
      50_u32 => Apprt::Key::ShiftLeft,
    }.each do |keycode, key|
      Apprt::Key.from_keycode(keycode).should eq key
    end
  end

  it "maps unknown keycodes to Unidentified" do
    Apprt::Key.from_keycode(0_u32).should eq Apprt::Key::Unidentified
    Apprt::Key.from_keycode(7_u32).should eq Apprt::Key::Unidentified
    Apprt::Key.from_keycode(100_000_u32).should eq Apprt::Key::Unidentified
  end
end
