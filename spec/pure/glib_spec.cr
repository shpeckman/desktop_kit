# spec/pure/glib_spec.cr
require "../spec_helper"
require "log/spec"

private class TestObject < Apprt::Wrapper
  def self.release_later(pointer : Void*) : Nil
    c_release(pointer)
  end
end

private enum Edge
  Top
  Bottom
end

private def ref_count(object : Void*) : UInt32
  (object.as(UInt32*) + 2).value
end

private def iterate_main_context : Nil
  while Apprt::C.g_main_context_iteration(Pointer(Void).null, 0) != 0
  end
end

private def new_action(name : String) : Void*
  Apprt::C.g_simple_action_new(name, Apprt::C.g_variant_type_new("i"))
end

describe Apprt::GLibError do
  it "converts and frees a GError" do
    raw = Apprt::C.g_error_new_literal(Apprt::C.g_quark_from_string("apprt-test"), 7, "broken")
    error = Apprt::GLibError.take(raw)
    error.domain.should eq "apprt-test"
    error.code.should eq 7
    error.message.should eq "broken"
  end

  it "raises the error a call reports" do
    expect_raises(Apprt::GLibError, /expected/) do
      Apprt::GLibError.check! do |error|
        Apprt::C.g_variant_parse(Pointer(Void).null, "(1,", Pointer(UInt8).null, Pointer(UInt8*).null, error)
      end
    end
  end

  it "returns the result when the call succeeds" do
    Apprt::GLibError.check! { |_error| 42 }.should eq 42
  end
end

describe Apprt::Native do
  it "converts strings" do
    Apprt::Native.string(nil).null?.should be_true
    Apprt::Native.string?(Pointer(UInt8).null).should be_nil
    Apprt::Native.string?("abc".to_unsafe).should eq "abc"
    Apprt::Native.take_string?(Apprt::C.g_strdup("dup")).should eq "dup"
  end

  it "builds and reads NULL-terminated vectors" do
    vector = Apprt::Native.strv(%w(a bc))
    vector.size.should eq 3
    vector.last.null?.should be_true
    Apprt::C.g_strv_length(vector).should eq 2
    Apprt::Native.strv?(vector.to_unsafe).should eq %w(a bc)
    Apprt::Native.strv?(Pointer(UInt8*).null).should be_empty
  end

  it "walks a GList" do
    values = [1, 2, 3]
    nodes = Array(Apprt::C::GList).new(3) { |i| Apprt::C::GList.new(data: (values.to_unsafe + i).as(Void*)) }
    nodes.to_unsafe.value.next_ = nodes.to_unsafe + 1
    (nodes.to_unsafe + 1).value.next_ = nodes.to_unsafe + 2
    seen = [] of Int32
    Apprt::Native.each(nodes.to_unsafe) { |data| seen << data.as(Int32*).value }
    seen.should eq values
  end
end

describe Apprt::Handles do
  it "retains, returns and releases values" do
    before = Apprt::Handles.size
    pointer = Apprt::Handles.retain("kept")
    Apprt::Handles.size.should eq before + 1
    Apprt::Handles.get(pointer, String).should eq "kept"
    Apprt::Handles.release(pointer)
    Apprt::Handles.size.should eq before
  end
end

describe Apprt::Wrapper do
  it "adopts or adds a reference" do
    raw = new_action("adopt")
    taken = TestObject.take(raw)
    ref_count(raw).should eq 1
    borrowed = TestObject.from_raw(raw)
    ref_count(raw).should eq 2
    (taken == borrowed).should be_true
    taken.hash.should eq borrowed.hash
  end

  it "maps null pointers" do
    TestObject.take?(Pointer(Void).null).should be_nil
    TestObject.from_raw?(Pointer(Void).null).should be_nil
    expect_raises(ArgumentError) { TestObject.take(Pointer(Void).null) }
  end

  it "drops object references on the main loop" do
    raw = new_action("later")
    Apprt::C.g_object_ref(raw)
    TestObject.release_later(raw)
    ref_count(raw).should eq 2
    iterate_main_context
    ref_count(raw).should eq 1
    Apprt::C.g_object_unref(raw)
  end
end

describe Apprt::Widget do
  it "rejects null pointers" do
    expect_raises(ArgumentError) { Apprt::Widget.new(Pointer(Void).null) }
    Apprt::Widget.new?(Pointer(Void).null).should be_nil
  end
end

# GMountOperation: a Gio object whose "reply" signal carries an enum.
lib SpecGio
  fun g_mount_operation_get_type : Apprt::C::GType
end

describe Apprt::Signals do
  it "converts arguments and releases the handler on disconnect" do
    action = TestObject.take(new_action("go"))
    received = [] of Int32?
    before = Apprt::Handles.size
    id = Apprt::Signals.connect(action, "activate", ->(parameter : Apprt::Variant?) { received << parameter.try(&.get(Int32)) })
    Apprt::Handles.size.should eq before + 1
    Apprt::Signals.connected?(action, id).should be_true
    Apprt::C.g_signal_emit_by_name(action, "activate", Apprt::Variant.new(5).to_unsafe)
    Apprt::C.g_signal_emit_by_name(action, "activate", Pointer(Void).null)
    Apprt::Signals.blocked(action, id) do
      Apprt::C.g_signal_emit_by_name(action, "activate", Apprt::Variant.new(6).to_unsafe)
    end
    received.should eq [5, nil]
    Apprt::Signals.disconnect(action, id)
    Apprt::Handles.size.should eq before
  end

  it "returns Bool results" do
    app = TestObject.take(Apprt::C.g_object_new_with_properties(Apprt::C.g_application_get_type, 0, Pointer(UInt8*).null, Pointer(Void).null))
    Apprt::Signals.connect(app, "name-lost", -> : Bool { true })
    result = 0
    Apprt::C.g_signal_emit_by_name(app, "name-lost", pointerof(result))
    result.should eq 1
  end

  it "converts enums and strings" do
    edges = [] of Edge
    operation = TestObject.take(Apprt::C.g_object_new_with_properties(SpecGio.g_mount_operation_get_type, 0, Pointer(UInt8*).null, Pointer(Void).null))
    Apprt::Signals.connect(operation, "reply", ->(edge : Edge) { edges << edge })
    Apprt::C.g_signal_emit_by_name(operation, "reply", 1)
    edges.should eq [Edge::Bottom]

    hints = [] of {Int32, String?}
    app = TestObject.take(Apprt::C.g_object_new_with_properties(Apprt::C.g_application_get_type, 0, Pointer(UInt8*).null, Pointer(Void).null))
    Apprt::Signals.connect(app, "open", ->(_files : Void*, count : Int32, hint : String?) { hints << {count, hint} })
    Apprt::C.g_signal_emit_by_name(app, "open", Pointer(Void).null, 0, "edit")
    Apprt::C.g_signal_emit_by_name(app, "open", Pointer(Void).null, 2, Pointer(UInt8).null)
    hints.should eq [{0, "edit"}, {2, nil}]
  end

  it "logs exceptions instead of raising through C" do
    action = TestObject.take(new_action("raise"))
    Apprt::Signals.connect(action, "activate", ->(_parameter : Void*) { raise "boom" })
    Log.capture("apprt") do |logs|
      Apprt::C.g_signal_emit_by_name(action, "activate", Pointer(Void).null)
      logs.check(:error, "activate handler")
      logs.entry.exception.try(&.message).should eq "boom"
    end
  end

  it "notifies property changes" do
    action = TestObject.take(new_action("notify"))
    count = 0
    Apprt::Signals.notify(action, "enabled", -> { count += 1 })
    Apprt::C.g_simple_action_set_enabled(action, 0)
    count.should eq 1
  end
end
