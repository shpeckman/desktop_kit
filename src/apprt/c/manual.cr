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

    PRIORITY_DEFAULT_IDLE = 200
    SOURCE_REMOVE         =   0
  end
end
