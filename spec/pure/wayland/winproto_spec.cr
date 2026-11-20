# spec/pure/wayland/winproto_spec.cr
require "../../spec_helper"

private alias Slice = DesktopKit::Winproto::Slice

describe DesktopKit::Winproto do
  describe ".slices" do
    it "is the whole rectangle without corners" do
      DesktopKit::Winproto.slices(2, 3, 100, 50, 0).should eq [Slice.new(2, 3, 100, 50)]
    end

    it "approximates rounded corners with rows of one pixel" do
      DesktopKit::Winproto.slices(0, 0, 100, 50, 3).should eq [
        Slice.new(0, 3, 100, 44),
        Slice.new(1, 0, 98, 1), Slice.new(1, 49, 98, 1),
        Slice.new(0, 1, 100, 1), Slice.new(0, 48, 100, 1),
        Slice.new(0, 2, 100, 1), Slice.new(0, 47, 100, 1),
      ]
    end

    it "indents the first rows of a 15 pixel radius" do
      slices = DesktopKit::Winproto.slices(10, 20, 200, 100, 15)
      slices.first.should eq Slice.new(10, 35, 200, 70)
      slices.size.should eq 31
      slices[1].should eq Slice.new(10 + 11, 20, 178, 1)
      slices[2].should eq Slice.new(10 + 11, 119, 178, 1)
      slices.last.y.should eq 20 + 100 - 1 - 14
    end
  end
end
