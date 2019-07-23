module MarcWrangler
  # Methods to extend ruby-marc DataField/ControlField objects allowing
  # comparison of normalized contents and removal of specified subfields from
  # comparison.
  #
  # A spec/config needs to be assigned via ComparableField.spec = my_spec
  # so that normalization/omission options are set.
  module ComparableField
    attr_accessor :omitted, :ac

    # normalized comparable string
    def norm_string
      @norm_string ||= ComparableField.norm_string(
        ComparableField.omitted_subfields_string(self)
      )
    end

    def self.spec=(spec)
      @tags_w_sf_omissions = spec['omit from comparison subfields']
      @spec = spec
    end

    def self.norm_string(str)
      fs = str.force_encoding('UTF-8').unicode_normalize.gsub(/ +$/, '')
      fs.gsub!(/(.)\uFE20(.)\uFE21/, "\\1\u0361\\2") if fs =~ /\uFE20/
      fs.gsub!(/\.$/, '') if @spec['ignore end of field periods in field comparison']
      fs
    end

    def self.omitted_subfields_string(field)
      return field.to_s unless @tags_w_sf_omissions&.key?(field.tag)

      sfs_to_omit = @tags_w_sf_omissions[field.tag].chars

      "#{field.tag} #{field.indicator1}#{field.indicator2} " \
      "#{field.subfields.reject { |sf| sfs_to_omit.include?(sf.code) }.map(&:to_s).join}"
    end
  end
end

class MARC::ControlField
  include MarcWrangler::ComparableField
end
class MARC::DataField
  include MarcWrangler::ComparableField
end
