# src/desktop_kit/core/translate.cr
module DesktopKit
  @@translator : String -> String = ->(text : String) { text }

  # Returns the function that translates desktop_kit's built-in texts.
  def self.translator : String -> String
    @@translator
  end

  # Sets the function that translates desktop_kit's built-in texts: labels,
  # tooltips, dialog texts and the titles of `Command.defaults` and
  # `Menu.window`. It receives the English text and returns the text to
  # show; the README lists every text desktop_kit passes.
  #
  # Set it before creating the application; texts already shown keep their
  # language.
  #
  # ```
  # DesktopKit.translator = ->(text : String) { GERMAN[text]? || text }
  # ```
  def self.translator=(translator : String -> String) : String -> String
    @@translator = translator
  end

  # :nodoc:
  # Translates the built-in *text*, falling back to it when the translator
  # raises.
  def self.tr(text : String) : String
    # Pass literals: spec/pure/core/translate_spec.cr scans src for
    # DesktopKit.tr literals (joining `\`-continued ones) and fails on one missing
    # from README's Translation table. New text: wrap it and add the row.
    @@translator.call(text)
  rescue ex
    Log.error(exception: ex) { "translator failed for #{text.inspect}" }
    text
  end
end
