# spec/pure/bindings_spec.cr
require "../spec_helper"

# One reference per library keeps the linker from dropping it.
private LINKED = {
  ->Apprt::C.g_strdup(UInt8*),
  ->Apprt::C.g_type_name(Apprt::C::GType),
  ->Apprt::C.g_application_id_is_valid(UInt8*),
  ->Apprt::C.gtk_paned_get_type,
  ->Apprt::C.adw_init,
}

describe "Apprt::C" do
  it "resolves every generated function in the linked libraries" do
    LINKED.size.should eq 5
    dir = File.expand_path("../../src/apprt/c", __DIR__)
    names = Dir.glob(File.join(dir, "*.cr")).flat_map do |path|
      File.read_lines(path).compact_map { |l| l.match(/^\s*fun (\w+)/).try(&.[1]) }
    end
    names.size.should be > 300
    missing = names.reject { |n| LibC.dlsym(LibC::RTLD_DEFAULT, n) }
    missing.should be_empty
  end

  it "registers GObject types" do
    String.new(Apprt::C.g_type_name(Apprt::C.gtk_paned_get_type)).should eq "GtkPaned"
  end

  it "lays out GValue as GLib does" do
    sizeof(Apprt::C::GValue).should eq 24
  end
end
