# src/desktop_kit/core/command_line.cr
require "uri"

module DesktopKit
  # The arguments of one launch of the application, from this process or
  # from a later launch that hands them to the running instance.
  #
  # ```
  # protected def on_command_line(command_line)
  #   return 2 if command_line.arguments.empty?
  #   on_open(command_line.arguments.map { |argument| command_line.path(argument) })
  #   0
  # end
  # ```
  struct CommandLine
    # Returns the arguments, without the program name.
    getter arguments : Array(String)

    # Returns the working directory of the launching process.
    getter directory : Path

    # Returns whether another process launched the application.
    getter? remote : Bool

    def initialize(@arguments : Array(String), @directory : Path = Path[Dir.current], @remote : Bool = false)
    end

    # Returns the file *argument* names: an absolute path, a path relative to
    # `#directory` or a `file://` URI.
    def path(argument : String) : Path
      if argument.starts_with?("file://")
        Path[URI.decode(URI.parse(argument).path)]
      else
        Path[argument].expand(@directory, home: false)
      end
    end

    # Copies the launch a `GApplicationCommandLine` describes.
    protected def self.from(command_line : Void*) : self
      count = 0
      arguments = Native.take_strv(C.g_application_command_line_get_arguments(command_line, pointerof(count)))
      directory = Native.string?(C.g_application_command_line_get_cwd(command_line))
      new(arguments[1..]? || [] of String, directory ? Path[directory] : Path[Dir.current],
        C.g_application_command_line_get_is_remote(command_line) != 0)
    end
  end
end
