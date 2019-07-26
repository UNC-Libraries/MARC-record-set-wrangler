# standard library
require 'date'

# external gems
require 'marc'
require 'highline/import'

# marc extension
require_relative 'ext/marc/reader'
require_relative 'ext/marc/record'
require_relative 'ext/marc/writer'

module MarcWrangler
  autoload :VERSION, 'marc_wrangler/version'
  autoload :Config, 'marc_wrangler/config'
  autoload :MarcEdit, 'marc_wrangler/marc_edit'
  autoload :ProcessHoldings, 'marc_wrangler/process_holdings'
  autoload :RecordComparer, 'marc_wrangler/record_comparer'

  require_relative 'marc_wrangler/comparable_field'
  require_relative 'marc_wrangler/record_info'
end
