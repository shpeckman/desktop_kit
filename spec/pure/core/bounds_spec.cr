# spec/pure/core/bounds_spec.cr
require "../../spec_helper"

private alias Bounds = DesktopKit::Bounds

describe DesktopKit::Bounds do
  describe "#moved" do
    it "shifts the bounds" do
      moved = Bounds.new(0.2, 0.3, 0.4, 0.5).moved(0.1, -0.2)
      moved.x.should be_close(0.3, 1e-12)
      moved.y.should be_close(0.1, 1e-12)
      moved.width.should eq 0.4
      moved.height.should eq 0.5
    end

    it "keeps the bounds inside the unit square" do
      Bounds.new(0.2, 0.3, 0.4, 0.5).moved(-1.0, -1.0).should eq Bounds.new(0.0, 0.0, 0.4, 0.5)
      Bounds.new(0.2, 0.3, 0.4, 0.5).moved(1.0, 1.0).should eq Bounds.new(0.6, 0.5, 0.4, 0.5)
    end
  end

  describe "#resized" do
    it "keeps the top-left corner" do
      resized = Bounds.new(0.2, 0.3, 0.4, 0.5).resized(0.1, -0.1, 0.0, 0.0)
      resized.x.should eq 0.2
      resized.y.should eq 0.3
      resized.width.should be_close(0.5, 1e-12)
      resized.height.should be_close(0.4, 1e-12)
    end

    it "honours the minimum" do
      Bounds.new(0.2, 0.3, 0.4, 0.5).resized(-1.0, -1.0, 0.1, 0.15).should eq Bounds.new(0.2, 0.3, 0.1, 0.15)
    end

    it "stops at the right and bottom edges" do
      resized = Bounds.new(0.2, 0.3, 0.4, 0.5).resized(1.0, 1.0, 0.0, 0.0)
      resized.x.should eq 0.2
      resized.y.should eq 0.3
      resized.width.should be_close(0.8, 1e-12)
      resized.height.should be_close(0.7, 1e-12)
    end
  end

  describe "#clamped" do
    it "shrinks oversize bounds to the unit square" do
      Bounds.new(0.5, 0.5, 3.0, 2.0).clamped.should eq Bounds.new(0.0, 0.0, 1.0, 1.0)
    end

    it "moves bounds past an edge back inside" do
      Bounds.new(0.9, -0.2, 0.5, 0.5).clamped.should eq Bounds.new(0.5, 0.0, 0.5, 0.5)
    end

    it "leaves bounds inside alone" do
      bounds = Bounds.new(0.1, 0.2, 0.3, 0.4)
      bounds.clamped.should eq bounds
    end
  end

  it "returns the center" do
    Bounds.new(0.2, 0.4, 0.4, 0.2).center.should eq({0.4, 0.5})
  end

  describe "#valid?" do
    it "accepts bounds inside the unit square" do
      Bounds.new(0.0, 0.0, 1.0, 1.0).valid?.should be_true
      Bounds.new(0.3, 0.3, 0.7, 0.7).valid?.should be_true
    end

    it "rejects NaN and infinite values" do
      Bounds.new(Float64::NAN, 0.0, 0.5, 0.5).valid?.should be_false
      Bounds.new(0.0, 0.0, 0.5, Float64::INFINITY).valid?.should be_false
    end

    it "rejects zero and negative sizes" do
      Bounds.new(0.1, 0.1, 0.0, 0.5).valid?.should be_false
      Bounds.new(0.1, 0.1, 0.5, -0.5).valid?.should be_false
    end

    it "rejects bounds past an edge" do
      Bounds.new(-0.1, 0.1, 0.5, 0.5).valid?.should be_false
      Bounds.new(0.6, 0.1, 0.5, 0.5).valid?.should be_false
      Bounds.new(0.1, 0.6, 0.5, 0.5).valid?.should be_false
    end
  end
end
