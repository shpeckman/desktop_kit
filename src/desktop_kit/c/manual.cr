# src/desktop_kit/c/manual.cr
#
# Bindings tools/gen_gir.cr cannot generate: GValue holds a union, so GIR
# describes it with a union member the generator leaves to this file; GIR
# constants are not generated.
module DesktopKit
  # :nodoc:
  lib C
    # GValue: the type and two 8-byte data slots of the C union
    # (gint, guint, glong, gint64, gfloat, gdouble, gpointer).
    struct GValue
      g_type : GType
      data : UInt64[2]
    end

    # GLib and GTK constants (GIR <constant>s, which the generator skips);
    # TYPE_INT, TYPE_UINT64 and TYPE_STRING are G_TYPE_MAKE_FUNDAMENTAL(6),
    # (11) and (16).
    TYPE_INT                            =  24_u64
    TYPE_UINT64                         =  44_u64
    TYPE_STRING                         =  64_u64
    PRIORITY_DEFAULT                    =       0
    PRIORITY_DEFAULT_IDLE               =     200
    SOURCE_REMOVE                       =       0
    SOURCE_CONTINUE                     =       1
    STYLE_PROVIDER_PRIORITY_APPLICATION = 600_u32
    STYLE_PROVIDER_PRIORITY_USER        = 800_u32
    PANGO_ELLIPSIZE_END                 =       3

    # The GIR marks GdkFileList's get-type function as introspectable="0".
    fun gdk_file_list_get_type : GType

    # Takes a PangoEllipsizeMode; Pango has no allowlist.
    fun gtk_label_set_ellipsize(label : Void*, mode : Int32)
  end
end
