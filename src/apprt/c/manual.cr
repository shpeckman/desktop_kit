# src/apprt/c/manual.cr
#
# Bindings tools/gen_gir.cr cannot generate: GValue holds a union, so GIR
# describes it with a union member the generator leaves to this file; GIR
# constants are not generated.
module Apprt
  # :nodoc:
  lib C
    # GValue: the type and two 8-byte data slots of the C union
    # (gint, guint, glong, gint64, gfloat, gdouble, gpointer).
    struct GValue
      g_type : GType
      data : UInt64[2]
    end

    # GLib and GTK constants (GIR <constant>s, which the generator skips).
    PRIORITY_DEFAULT                    =       0
    PRIORITY_DEFAULT_IDLE               =     200
    SOURCE_REMOVE                       =       0
    STYLE_PROVIDER_PRIORITY_APPLICATION = 600_u32
    STYLE_PROVIDER_PRIORITY_USER        = 800_u32
  end
end
