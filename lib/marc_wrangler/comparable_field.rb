module MarcWrangler
  # Methods to extend ruby-marc DataField/ControlField objects allowing
  # comparison of normalized contents and removal of specified subfields from
  # comparison.
  #
  # A spec/config needs to be assigned via ComparableField.spec = my_spec
  # so that normalization/omission options are set.
  module ComparableField

    # normalized comparable string
    def norm_string
      ComparableField.norm_string(
        ComparableField.omitted_subfields_string(self)
      )
    end

    def self.spec=(spec)
      @tags_w_sf_omissions = spec['omit from comparison subfields']
      @ignore_trailing_periods = spec['ignore end of field periods in field comparison']
    end

    def self.norm_string(str)
      # ruby-marc assumes files are utf-8 unless another encoding is specified;
      # LDR/09 value is not considered. If the string includes invalid encoding
      # for utf-8, try assuming marc-8 encoding. If string is not valid marc-8
      # either, return the string for comparison unnormalized (which for diffing
      # two strings should be better than scrubbing invalid bytes).
      begin
        fs = str.force_encoding('UTF-8').unicode_normalize
      rescue ArgumentError
        begin
          fs = marc8_transcoder.transcode(str).unicode_normalize
        rescue StandardError
          return str.dup
        end
      end
      fs.rstrip!
      fs.gsub!(/(.)\uFE20(.)\uFE21/, "\\1\u0361\\2") if fs =~ /\uFE20/
      fs.gsub!(/\.$/, '') if @ignore_trailing_periods
      fs
    end

    def self.marc8_transcoder
      return @marc8_transcoder if @marc8_transcoder
      require 'marc/marc8/to_unicode'
      @marc8_transcoder = MARC::Marc8::ToUnicode.new
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
