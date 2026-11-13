# tools/gir/generator.cr
#
# Reader and emitter of GObject Introspection repositories (GIR XML) for
# tools/gen_gir.cr: a `lib C` per namespace holding the functions, enums,
# bitfields, callbacks, records and `*_get_type` functions an allowlist names.
#
# Allowlist: one C identifier per line, `#` starts a comment.
#   function, method or constructor  its `c:identifier`  (gtk_paned_new)
#   enum, bitfield, callback, record its `c:type`        (GtkOrientation)
#   class or interface               its `c:type`, emits `glib:get-type` (GtkPaned)
# Enums, bitfields and callbacks a listed symbol uses are pulled in by
# themselves; a record is a struct only when listed, else a pointer to it is
# `Void*`. Output keeps allowlist order.
require "xml"

module GirGenerator
  class Error < Exception
  end

  KEYWORDS = %w(abstract alias annotation as asm begin break case class def do else elsif end ensure enum extend
    false for fun if in include instance_sizeof lib macro module next nil of offsetof out pointerof private
    protected require rescue return select self sizeof struct super then true type typeof uninitialized
    union unless until verbatim when while with yield)

  # C (and GIR) base type names → Crystal type and the pointer depth the name carries.
  PRIMITIVES = {
    "void" => {"Void", 0}, "none" => {"Void", 0},
    "gpointer" => {"Void", 1}, "gconstpointer" => {"Void", 1},
    "char" => {"UInt8", 0}, "gchar" => {"UInt8", 0}, "guchar" => {"UInt8", 0}, "unsigned char" => {"UInt8", 0},
    "utf8" => {"UInt8", 1}, "filename" => {"UInt8", 1}, "GStrv" => {"UInt8", 2}, "GRefString" => {"UInt8", 0},
    "gint8" => {"Int8", 0}, "int8_t" => {"Int8", 0}, "signed char" => {"Int8", 0},
    "guint8" => {"UInt8", 0}, "uint8_t" => {"UInt8", 0},
    "gshort" => {"Int16", 0}, "short" => {"Int16", 0}, "gint16" => {"Int16", 0}, "int16_t" => {"Int16", 0},
    "gushort" => {"UInt16", 0}, "unsigned short" => {"UInt16", 0}, "guint16" => {"UInt16", 0},
    "uint16_t" => {"UInt16", 0}, "gunichar2" => {"UInt16", 0},
    "gint" => {"Int32", 0}, "int" => {"Int32", 0}, "gint32" => {"Int32", 0}, "int32_t" => {"Int32", 0},
    "gboolean" => {"Int32", 0}, "GPid" => {"Int32", 0}, "pid_t" => {"Int32", 0},
    "guint" => {"UInt32", 0}, "unsigned int" => {"UInt32", 0}, "unsigned" => {"UInt32", 0},
    "guint32" => {"UInt32", 0}, "uint32_t" => {"UInt32", 0}, "gunichar" => {"UInt32", 0},
    "GQuark" => {"UInt32", 0}, "uid_t" => {"UInt32", 0},
    "gint64" => {"Int64", 0}, "int64_t" => {"Int64", 0}, "goffset" => {"Int64", 0},
    "guint64" => {"UInt64", 0}, "uint64_t" => {"UInt64", 0},
    "glong" => {"LibC::Long", 0}, "long" => {"LibC::Long", 0}, "time_t" => {"LibC::Long", 0},
    "gulong" => {"LibC::ULong", 0}, "unsigned long" => {"LibC::ULong", 0},
    "gsize" => {"LibC::SizeT", 0}, "size_t" => {"LibC::SizeT", 0},
    "guintptr" => {"LibC::SizeT", 0}, "uintptr_t" => {"LibC::SizeT", 0},
    "gssize" => {"LibC::SSizeT", 0}, "ssize_t" => {"LibC::SSizeT", 0},
    "gintptr" => {"LibC::SSizeT", 0}, "intptr_t" => {"LibC::SSizeT", 0},
    "gfloat" => {"Float32", 0}, "float" => {"Float32", 0},
    "gdouble" => {"Float64", 0}, "double" => {"Float64", 0},
    "GType" => {"GType", 0},
  }

  # One allowlist line.
  record Entry, id : String, file : String, line : Int32

  # The entries of allowlist *text* read from *file*.
  def self.parse_allowlist(text : String, file : String) : Array(Entry)
    entries = [] of Entry
    text.each_line.with_index(1) do |raw, line|
      id = raw.split('#', 2)[0].strip
      next if id.empty?
      raise Error.new("#{file}:#{line}: more than one identifier on a line") if id.includes?(' ')
      entries << Entry.new(id, file, line)
    end
    entries
  end

  # The value of attribute *name* in XML namespace *prefix* (nil: no prefix).
  def self.attr(node : XML::Node, name : String, prefix : String? = nil) : String?
    node.attributes.each do |a|
      next unless a.name == name
      return a.content if a.namespace.try(&.prefix) == prefix
    end
    nil
  end

  def self.elements(node : XML::Node, name : String? = nil) : Array(XML::Node)
    node.children.select { |c| c.element? && c.namespace.try(&.prefix).nil? && (name.nil? || c.name == name) }
  end

  def self.ident(name : String) : String
    n = name.gsub('-', '_')
    n = "_#{n}" if n[0].ascii_number?
    KEYWORDS.includes?(n) ? "#{n}_" : n
  end

  def self.camel(name : String) : String
    n = name.split(/[_-]/).reject(&.empty?).map(&.capitalize).join
    n[0].ascii_number? ? "N#{n}" : n
  end

  # A GIR namespace: its package and its symbols by C name.
  class Namespace
    getter name : String
    getter version : String
    getter package : String?
    # Functions, methods and constructors by `c:identifier`.
    getter functions = {} of String => XML::Node
    # Enumerations, bitfields, callbacks, records, unions, classes, interfaces and aliases by `c:type`.
    getter types = {} of String => XML::Node
    # GIR name ("Widget") → `c:type`.
    getter c_types = {} of String => String

    def initialize(@name, @version, @package)
    end

    def key : String
      "#{@name}-#{@version}"
    end
  end

  # GIR files loaded from a directory, with the namespaces they include.
  class Repository
    getter namespaces = {} of String => Namespace
    @docs = [] of XML::Node

    def initialize(@dir : String)
    end

    # Loads namespace *key* ("Gtk-4.0") and, when their files exist, the namespaces it includes.
    def load(key : String) : Namespace
      @namespaces.each_value { |ns| return ns if ns.key == key }
      path = File.join(@dir, "#{key}.gir")
      raise Error.new("no #{path}") unless File.exists?(path)
      doc = XML.parse(File.read(path))
      @docs << doc
      root = doc.first_element_child || raise Error.new("#{path}: empty")
      GirGenerator.elements(root, "include").each do |inc|
        k = "#{inc["name"]}-#{inc["version"]}"
        load(k) if File.exists?(File.join(@dir, "#{k}.gir"))
      end
      package = GirGenerator.elements(root, "package").first?.try(&.["name"])
      node = GirGenerator.elements(root, "namespace").first? || raise Error.new("#{path}: no namespace")
      ns = Namespace.new(node["name"], node["version"], package)
      index(ns, node)
      @namespaces[ns.name] = ns
    end

    private def index(ns : Namespace, node : XML::Node) : Nil
      GirGenerator.elements(node).each do |el|
        case el.name
        when "function"
          add_function(ns, el)
        when "enumeration", "bitfield", "callback", "record", "union", "class", "interface", "alias"
          if ctype = GirGenerator.attr(el, "type", "c") || GirGenerator.attr(el, "type-name", "glib")
            ns.types[ctype] = el
            ns.c_types[el["name"]] = ctype
          end
          GirGenerator.elements(el).each do |m|
            add_function(ns, m) if m.name.in?("function", "method", "constructor")
          end
        end
      end
    end

    private def add_function(ns : Namespace, el : XML::Node) : Nil
      if id = GirGenerator.attr(el, "identifier", "c")
        ns.functions[id] = el
      end
    end

    def function?(id : String) : {Namespace, XML::Node}?
      @namespaces.each_value { |ns| ns.functions[id]?.try { |n| return {ns, n} } }
      nil
    end

    def type?(ctype : String) : {Namespace, XML::Node}?
      @namespaces.each_value { |ns| ns.types[ctype]?.try { |n| return {ns, n} } }
      nil
    end

    # The `c:type` of GIR name *name* ("Gtk.Widget", or "Widget" within *ns*).
    def c_type?(name : String, ns : Namespace) : String?
      if name.includes?('.')
        nsname, local = name.split('.', 2)
        @namespaces[nsname]?.try(&.c_types[local]?)
      else
        ns.c_types[name]?
      end
    end
  end

  # The declarations of one namespace, in emission order.
  class Output
    getter enums = [] of String
    getter callbacks = [] of String
    getter structs = [] of String
    getter funs = [] of String
    getter seen = Set(String).new
    getter listed = false

    def listed! : Nil
      @listed = true
    end
  end

  # Renders allowlisted symbols of a `Repository` into per-namespace `lib C` bodies.
  class Generator
    getter outputs = {} of String => Output
    @records = Set(String).new

    # Renders *allowlists*, each the entries of one namespace of *repo*.
    def initialize(@repo : Repository, allowlists : Array({Namespace, Array(Entry)}))
      allowlists.each do |(_, entries)|
        entries.each do |e|
          if found = @repo.type?(e.id)
            @records << e.id if found[1].name == "record"
          end
        end
      end
      allowlists.each { |(ns, entries)| add(ns, entries) }
    end

    private def add(ns : Namespace, entries : Array(Entry)) : Nil
      output(ns.name).listed!
      entries.each do |e|
        if found = @repo.function?(e.id)
          add_function(found[0], found[1])
        elsif found = @repo.type?(e.id)
          add_type(e, found[0], found[1])
        else
          raise Error.new("#{e.file}:#{e.line}: unknown symbol #{e.id}")
        end
      end
    end

    # Writes namespace *ns* as `module MOD; lib C` to *io*; *header* lines go first as comments.
    def emit(ns : Namespace, io : IO, mod : String, header : Array(String)) : Nil
      output = @outputs[ns.name]? || Output.new
      header.each { |h| io << (h.empty? ? "#" : "# #{h}") << '\n' }
      io << "module " << mod << '\n'
      io << "  # :nodoc:\n"
      io << "  @[Link(pkg_config: " << ns.package.inspect << ")]\n" if ns.package
      io << "  lib C\n"
      io << "    alias GType = LibC::SizeT\n\n" if ns.name == "GLib"
      {output.enums, output.callbacks, output.structs}.each do |list|
        list.each { |d| io << d << '\n' }
      end
      output.funs.each { |d| io << d << '\n' }
      io << "  end\nend\n"
    end

    # Namespaces that received auto-pulled declarations but have no allowlist.
    def unlisted : Array(String)
      @outputs.select { |_, o| !o.listed && (o.enums.any? || o.callbacks.any? || o.structs.any? || o.funs.any?) }.keys
    end

    private def output(name : String) : Output
      @outputs[name] ||= Output.new
    end

    private def add_type(e : Entry, ns : Namespace, node : XML::Node) : Nil
      ctype = e.id
      case node.name
      when "enumeration", "bitfield" then pull_enum(ns, ctype, node)
      when "callback"                then pull_callback(ns, ctype, node)
      when "record"                  then add_record(ns, ctype, node)
      when "class", "interface"
        getter = GirGenerator.attr(node, "get-type", "glib")
        if getter.nil? || getter == "intern"
          raise Error.new("#{e.file}:#{e.line}: #{ctype} has no get-type function")
        end
        o = output(ns.name)
        o.funs << "    fun #{getter} : GType" if o.seen.add?(getter)
      else
        raise Error.new("#{e.file}:#{e.line}: #{ctype} is a #{node.name}, not supported")
      end
    end

    private def add_function(ns : Namespace, node : XML::Node) : Nil
      id = GirGenerator.attr(node, "identifier", "c").not_nil!
      o = output(ns.name)
      return unless o.seen.add?(id)
      params, ret = signature(node, ns, id)
      decl = "    fun #{id}"
      decl += "(#{params.join(", ")})" unless params.empty?
      decl += " : #{ret}" unless ret == "Void"
      o.funs << decl
    end

    # The Crystal parameters ("name : Type") and return type of function or callback *node*.
    private def signature(node : XML::Node, ns : Namespace, where : String) : {Array(String), String}
      params = [] of String
      if plist = GirGenerator.elements(node, "parameters").first?
        GirGenerator.elements(plist).each do |p|
          next unless p.name.in?("parameter", "instance-parameter")
          if GirGenerator.elements(p, "varargs").any?
            params << "..."
            next
          end
          type = param_type(p, ns, "#{where}(#{p["name"]?})")
          params << "#{GirGenerator.ident(p["name"]? || "arg#{params.size}")} : #{type}"
        end
      end
      if node["throws"]? == "1"
        params.insert(params.index("...") || params.size, "error : #{@records.includes?("GError") ? "GError" : "Void"}**")
      end
      ret = "Void"
      if rv = GirGenerator.elements(node, "return-value").first?
        ret = param_type(rv, ns, "#{where} return value")
      end
      {params, ret}
    end

    private def param_type(p : XML::Node, ns : Namespace, where : String) : String
      t = GirGenerator.elements(p).find { |c| c.name.in?("type", "array") } ||
          raise Error.new("#{where}: no type")
      outp = p["direction"]?.in?("out", "inout")
      type_of(t, ns, where, outp)
    end

    # The Crystal type of `<type>` or `<array>` element *t*.
    private def type_of(t : XML::Node, ns : Namespace, where : String, outp : Bool = false) : String
      if ctype = GirGenerator.attr(t, "type", "c")
        return map_ctype(ctype, t, ns, where)
      end
      if t.name == "array"
        inner = GirGenerator.elements(t).find { |c| c.name.in?("type", "array") } ||
                raise Error.new("#{where}: array without element type")
        return type_of(inner, ns, where) + "*" + (outp ? "*" : "")
      end
      name = t["name"]? || raise Error.new("#{where}: type without name")
      if prim = PRIMITIVES[name]?
        return pointer(prim[0], prim[1] + (outp ? 1 : 0))
      end
      ctype = @repo.c_type?(name, ns) || raise Error.new("#{where}: unknown type #{name}")
      found = @repo.type?(ctype).not_nil!
      depth = found[1].name.in?("enumeration", "bitfield", "callback", "alias") ? 0 : 1
      map_ctype(ctype + "*" * (depth + (outp ? 1 : 0)), t, ns, where)
    end

    private def pointer(base : String, depth : Int32) : String
      base + "*" * depth
    end

    # The Crystal type of C type *ctype*, pulling in the enums and callbacks it names.
    private def map_ctype(ctype : String, t : XML::Node, ns : Namespace, where : String) : String
      base = ctype.gsub(/\b(const|volatile|struct)\b/, " ")
      depth = base.count('*')
      base = base.delete('*').split.join(' ')
      if prim = PRIMITIVES[base]?
        return pointer(prim[0], prim[1] + depth)
      end
      if found = @repo.type?(base)
        tns, node = found
        case node.name
        when "enumeration", "bitfield"
          pull_enum(tns, base, node)
          return pointer(base, depth)
        when "callback"
          pull_callback(tns, base, node)
          return pointer(base, depth)
        when "alias"
          target = GirGenerator.elements(node, "type").first? || raise Error.new("#{where}: alias #{base} has no type")
          return pointer(type_of(target, tns, where), depth)
        else
          return pointer(base, depth) if @records.includes?(base)
          return pointer("Void", depth) if depth > 0
          raise Error.new("#{where}: #{base} passed by value; list it as a record or bind it in c/manual.cr")
        end
      end
      return pointer("Void", depth) if depth > 0
      raise Error.new("#{where}: unknown type #{ctype}")
    end

    private def pull_enum(ns : Namespace, ctype : String, node : XML::Node) : Nil
      o = output(ns.name)
      return unless o.seen.add?(ctype)
      flags = node.name == "bitfield"
      members = [] of {String, Int64}
      names = Set(String).new
      GirGenerator.elements(node, "member").each do |m|
        value = m["value"].to_i64
        value &= 0xFFFFFFFF_i64 if flags
        name = GirGenerator.camel(m["name"])
        next if flags && (value == 0 || name.in?("None", "All"))
        next unless names.add?(name)
        members << {name, value}
      end
      base = if flags
               "UInt32"
             elsif members.any? { |(_, v)| v > Int32::MAX }
               members.any? { |(_, v)| v < 0 } ? "Int64" : "UInt32"
             else
               "Int32"
             end
      o.enums << String.build do |io|
        io << "    @[Flags]\n" if flags
        io << "    enum " << ctype << " : " << base << '\n'
        members.each { |(n, v)| io << "      " << n << " = " << v << '\n' }
        io << "    end\n"
      end
    end

    private def pull_callback(ns : Namespace, ctype : String, node : XML::Node) : Nil
      o = output(ns.name)
      return unless o.seen.add?(ctype)
      params, ret = signature(node, ns, ctype)
      types = params.map { |p| p == "..." ? raise Error.new("#{ctype}: variadic callback") : p.split(" : ", 2)[1] }
      o.callbacks << "    alias #{ctype} = #{types.join(", ")}#{types.empty? ? "" : " "}-> #{ret}"
    end

    private def add_record(ns : Namespace, ctype : String, node : XML::Node) : Nil
      o = output(ns.name)
      return unless o.seen.add?(ctype)
      fields = GirGenerator.elements(node, "field")
      raise Error.new("#{ctype}: opaque record (no fields)") if fields.empty?
      raise Error.new("#{ctype}: has a union member; bind it in c/manual.cr") if GirGenerator.elements(node, "union").any?
      o.structs << String.build do |io|
        io << "    struct " << ctype << '\n'
        fields.each do |f|
          where = "#{ctype}.#{f["name"]}"
          raise Error.new("#{where}: bit field; bind #{ctype} in c/manual.cr") if f["bits"]?
          t = GirGenerator.elements(f).find { |c| c.name.in?("type", "array", "callback") } ||
              raise Error.new("#{where}: no type")
          type = case t.name
                 when "callback" then "Void*"
                 when "array"
                   if size = t["fixed-size"]?
                     inner = GirGenerator.elements(t).find { |c| c.name.in?("type", "array") } ||
                             raise Error.new("#{where}: array without element type")
                     "#{type_of(inner, ns, where)}[#{size}]"
                   else
                     type_of(t, ns, where)
                   end
                 else type_of(t, ns, where)
                 end
          io << "      " << GirGenerator.ident(f["name"]) << " : " << type << '\n'
        end
        io << "    end\n"
      end
    end
  end
end
