module Templates
  NAMES = %w[cyber flower earth office kids].freeze

  Template = Struct.new(:name, :frontend_md, :fonts_html, keyword_init: true)

  def self.find(name)
    raise ArgumentError, "unknown template: #{name.inspect}" unless known?(name)
    Template.new(
      name: name,
      frontend_md: File.read(root.join(name, "frontend.md")),
      fonts_html:  File.read(root.join(name, "fonts.html"))
    )
  end

  def self.known?(name)
    return false if name.to_s.empty?
    NAMES.include?(name) && root.join(name).directory?
  end

  def self.root
    Rails.root.join("lib/templates")
  end
end
