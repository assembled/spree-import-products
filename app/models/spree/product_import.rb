# This model is the master routine for uploading products
# Requires Paperclip and CSV to upload the CSV file and read it nicely.

# Original Author:: Josh McArthur
# License:: MIT
module Spree
  class ProductError < StandardError; end;
  class ImportError < StandardError; end;
  class SkuError < StandardError; end;

  class ProductImport < ActiveRecord::Base
    attr_accessible :data_file, :data_file_file_name, :data_file_content_type, :data_file_file_size, :data_file_updated_at, :product_ids, :state, :failed_at, :completed_at
    has_attached_file :data_file, :path => ":rails_root/lib/etc/product_data/data-files/:basename.:extension"
    validates_attachment_presence :data_file

    after_destroy :destroy_products

    serialize :product_ids, Array
    cattr_accessor :settings

    def products
      Product.where :id => product_ids
    end

    require 'csv'
    require 'pp'
    require 'open-uri'

    def destroy_products
      products.destroy_all
    end

    state_machine :initial => :created do

      event :start do
        transition :to => :started, :from => :created
      end
      event :complete do
        transition :to => :completed, :from => :started
      end
      event :failure do
        transition :to => :failed, :from => :started
      end

      before_transition :to => [:failed] do |import|
        import.product_ids = []
        import.failed_at = Time.now
        import.completed_at = nil
      end

      before_transition :to => [:completed] do |import|
        import.failed_at = nil
        import.completed_at = Time.now
      end
    end

    def state_datetime
      if failed?
        failed_at
      elsif completed?
        completed_at
      else
        Time.now
      end
    end

    ## Data Importing:
    # List Price maps to Master Price, Current MAP to Cost Price, Net 30 Cost unused
    # Width, height, Depth all map directly to object
    # Image main is created independtly, then each other image also created and associated with the product
    # Meta keywords and description are created on the product model

    def import_data!(_transaction=true)
      require_master_price = Spree::Config[:require_master_price]
      Spree::Config[:require_master_price] = false
      
      start
      if _transaction
        transaction do
          _import_data
        end
      else
        _import_data
      end
      Spree::Config[:require_master_price] = require_master_price
    rescue Exception => exp
      Spree::Config[:require_master_price] = require_master_price
      log("An error occurred during import, please check file and try again. (#{exp.message})\n#{exp.backtrace.join('\n')}", :error)
      failure
      raise ImportError, exp.message
    end

    def _import_data
      begin
        #Get products *before* import -
        @products_before_import = Spree::Product.all
        @names_of_products_before_import = @products_before_import.map(&:name)

        rows = CSV.read(self.data_file.path, {encoding: 'UTF-8'})

        if ProductImport.settings[:first_row_is_headings]
          col = get_column_mappings(rows[0])
        else
          col = ProductImport.settings[:column_mappings]
        end

        log("Importing products for #{self.data_file_file_name} began at #{Time.now}")
        rows[ProductImport.settings[:rows_to_skip]..-1].each do |row|

          product_information = {}

          #Automatically map 'mapped' fields to a collection of product information.
          #NOTE: This code will deal better with the auto-mapping function - i.e. if there
          #are named columns in the spreadsheet that correspond to product
          # and variant field names.

          col.each do |key, value|
            #Trim whitespace off the beginning and end of row fields
            row[value].try :strip!
            row[value].try(:gsub!, /\n+/, "\n")
            product_information[key] = row[value]
          end

          #Manually set available_on if it is not already set
          product_information[:available_on] = Date.today - 1.day if product_information[:available_on].nil?
          #product_information[:price] = 0
          log("#{pp product_information}")

          variant_comparator_field = ProductImport.settings[:variant_comparator_field].try :to_sym
          variant_comparator_column = col[variant_comparator_field]
          
          variant_comparator_field = :sku if variant_comparator_field == :master_sku || variant_comparator_field == :parent_sku

          if ProductImport.settings[:create_variants] and variant_comparator_column and 
            (p = variant_comparator_field == :sku ? Variant.where(variant_comparator_field => row[variant_comparator_column]).first.try(:product) : Product.where(variant_comparator_field => row[variant_comparator_column]).first)
            # if variant_comparator_field == :sku
            #   p = Variant.where(variant_comparator_field => row[variant_comparator_column]).first.product
            # else
            #   p = Product.where(variant_comparator_field => row[variant_comparator_column]).first
            # end
            
            log("found product with this field #{variant_comparator_field}=#{row[variant_comparator_column]}")
            p.update_attribute(:deleted_at, nil) if p.deleted_at #Un-delete product if it is there
            p.variants.each { |variant| variant.update_attribute(:deleted_at, nil) }
            create_variant_for(p, :with => product_information)
          else
            next unless create_product_using(product_information)
          end
        end

        if ProductImport.settings[:destroy_original_products]
          @products_before_import.each { |p| p.destroy }
        end

        log("Importing products for #{self.data_file_file_name} completed at #{DateTime.now}")
      end
      #All done!
      complete
      return [:notice, "Product data was successfully imported."]
    end

    private


    # create_variant_for
    # This method assumes that some form of checking has already been done to
    # make sure that we do actually want to create a variant.
    # It performs a similar task to a product, but it also must pick up on
    # size/color options
    def create_variant_for(product, options = {:with => {}})
      return if options[:with].nil?

      # Just update variant if exists
      variant = Variant.find_by_sku(options[:with][:sku])
      raise SkuError, "SKU #{variant.sku} should belongs to #{product.inspect} but was #{variant.product.inspect}" if variant && variant.product != product
      if !variant
        variant = product.variants.new
        variant.id = options[:with][:id]
      else
        options[:with].delete(:id)
      end

      field = ProductImport.settings[:variant_comparator_field]
      log  "VARIANT:: #{variant.inspect}  /// #{options.inspect } /// #{options[:with][field]} /// #{field}"

      #Remap the options - oddly enough, Spree's product model has master_price and cost_price, while
      #variant has price and cost_price.
      options[:with][:price] = options[:with].delete(:price)

      #First, set the primitive fields on the object (prices, etc.)
      options[:with].each do |field, value|
        value = "" if field.to_s == "sku" && value.nil?
        variant.send("#{field}=", value) if variant.respond_to?("#{field}=")
        applicable_option_type = OptionType.find(:first, :conditions => [
          "lower(presentation) = ? OR lower(name) = ?",
          field.to_s.gsub('_',' '), field.to_s.gsub('_',' ')]
        )
        if applicable_option_type.is_a?(OptionType)
          product.option_types << applicable_option_type unless product.option_types.include?(applicable_option_type)
          opt_value = applicable_option_type.option_values.where(["presentation = ? OR name = ?", value, value]).first
          opt_value = applicable_option_type.option_values.create(:presentation => value, :name => value) unless opt_value
          variant.option_values << opt_value unless variant.option_values.include?(opt_value)
        end
      end

      log "VARIANT PRICE #{variant.inspect} /// #{variant.price}"

      if variant.valid?
        variant.save

        #Associate our new variant with any new taxonomies
        log("Associating taxonomies")
        taxonomy = options[:with][:taxonomy]
        if taxonomy.present?
          taxonomy_name = options[:with][:taxonomy].split(/\s*>\s*/).shift
          associate_product_with_taxon(variant.product, taxonomy_name, taxonomy)
        end
        # ProductImport.settings[:taxonomy_fields].each do |field|
        #   log("taxonomy_field: #{field} - #{options[:with][field.to_sym]}")
        #   associate_product_with_taxon(variant.product, field.to_s, options[:with][field.to_sym])
        # end

        #Finally, attach any images that have been specified
        ProductImport.settings[:image_fields].each do |field|
          find_and_attach_image_to(variant, options[:with][field.to_sym])
        end

        #Log a success message
        log("Variant of SKU #{variant.sku} successfully imported.\n")
      else
        log("A variant could not be imported - here is the information we have:\n" +
            "#{pp options[:with]}, #{variant.errors.full_messages.join(', ')}")
        return false
      end
    end


    # create_product_using
    # This method performs the meaty bit of the import - taking the parameters for the
    # product we have gathered, and creating the product and related objects.
    # It also logs throughout the method to try and give some indication of process.
    def create_product_using(params_hash)

      product         = Product.new
      properties_hash = Hash.new

      # Array of special fields. Prevent adding them to properties.
      special_fields  = ProductImport.settings.values_at(
                          :image_fields,
                          :taxonomy_fields,
                          :store_field,
                          :variant_comparator_field
                        ).flatten.map(&:to_s)

      #The product is inclined to complain if we just dump all params
      # into the product (including images and taxonomies).
      # What this does is only assigns values to products if the product accepts that field.
      params_hash.each do |field, value|
        if product.respond_to?("#{field}=")
          product.send("#{field}=", value) if value.present?
        elsif not special_fields.include?(field.to_s) and property = Property.where(:name => field.to_s.gsub('_',' ')).first
          properties_hash[property] = value
        end
      end

      after_product_built(product, params_hash)

      #We can't continue without a valid product here
      unless product.valid?
        log(msg = "A product could not be imported - here is the information we have:\n" +
            "#{pp params_hash}, #{product.errors.full_messages.join(', ')}")
        raise ProductError, msg
      end

      #Just log which product we're processing
      log(product.name)

      #This should be caught by code in the main import code that checks whether to create
      #variants or not. Since that check can be turned off, however, we should double check.
      p = Product.find_by_name(product.name)
      if @names_of_products_before_import.include? product.name and p.deleted_at.nil?
        log("#{product.name} is already in the system and active.\n")
      else
        if !p.nil? && !p.deleted_at.nil?
          p.destroy
          log("#{product.name} was removed from the system and will be replaced.\n")
        end
        
        #Save the object before creating associated objects
        product.save and product_ids << product.id

        #Associate properties with product
        properties_hash.each do |property, value|
          # product_property = ProductProperty.where(:product_id => product.id, :property_id => property.id).first_or_initialize
          # product_property.value = value
          # product_property.save!

          if value.present?
            value.split(",").each do |property_value|
              product_property = ProductProperty.where(:product_id => product.id, :property_id => property.id, :value => property_value.strip).first_or_initialize
              product_property.save!
            end
          end
          
        end

        #Associate our new product with any taxonomies that we need to worry about
        taxonomy = params_hash[:taxonomy]
        if taxonomy.present?
          taxonomy_name = params_hash[:taxonomy].split(/\s*>\s*/).shift
          associate_product_with_taxon(product, taxonomy_name, taxonomy)
        end
        # ProductImport.settings[:taxonomy_fields].each do |field|
        #   associate_product_with_taxon(product, field.to_s, params_hash[field.to_sym])
        # end

        #Finally, attach any images that have been specified
        ProductImport.settings[:image_fields].each do |field|
          find_and_attach_image_to(product, params_hash[field.to_sym])
        end

        if ProductImport.settings[:multi_domain_importing] && product.respond_to?(:stores)
          begin
            store = Store.find(
              :first,
              :conditions => ["id = ? OR code = ?",
                params_hash[ProductImport.settings[:store_field]],
                params_hash[ProductImport.settings[:store_field]]
              ]
            )

            product.stores << store
          rescue
            log("#{product.name} could not be associated with a store. Ensure that Spree's multi_domain extension is installed and that fields are mapped to the CSV correctly.")
          end
        end

        #Log a success message
        log("#{product.name} successfully imported.\n")
      end
      return true
    end

    # get_column_mappings
    # This method attempts to automatically map headings in the CSV files
    # with fields in the product and variant models.
    # If the headings of columns are going to be called something other than this,
    # or if the files will not have headings, then the manual initializer
    # mapping of columns must be used.
    # Row is an array of headings for columns - SKU, Master Price, etc.)
    # @return a hash of symbol heading => column index pairs
    def get_column_mappings(row)
      mappings = {}
      row.each_with_index do |heading, index|
        # Stop collecting headings, if heading is empty
        if not heading.blank?
          mappings[heading.downcase.gsub(/\A\s*/, '').chomp.gsub(/\s/, '_').to_sym] = index
        else
          break
        end
      end
      mappings
    end


    ### MISC HELPERS ####

    #Log a message to a file - logs in standard Rails format to logfile set up in the import_products initializer
    #and console.
    #Message is string, severity symbol - either :info, :warn or :error

    def log(message, severity = :info)
      @rake_log ||= ActiveSupport::BufferedLogger.new(ProductImport.settings[:log_to])
      message = "[#{Time.now.to_s(:db)}] [#{severity.to_s.capitalize}] #{message}\n"
      @rake_log.send severity, message
      puts message
    end


    ### IMAGE HELPERS ###

    # find_and_attach_image_to
    # This method attaches images to products. The images may come
    # from a local source (i.e. on disk), or they may be online (HTTP/HTTPS).
    def find_and_attach_image_to(product_or_variant, filename)
      return if filename.blank?

      #The image can be fetched from an HTTP or local source - either method returns a Tempfile
      file = filename =~ /\Ahttp[s]*:\/\// ? fetch_remote_image(filename) : fetch_local_image(filename)
      #An image has an attachment (the image file) and some object which 'views' it
      product_image = Image.new({:attachment => file,
                                :viewable_id => product_or_variant.id,
                                :viewable_type => product_or_variant.class.name,
                                :position => product_or_variant.images.length
                                })

      product_or_variant.images << product_image if product_image.save
    end

    # This method is used when we have a set location on disk for
    # images, and the file is accessible to the script.
    # It is basically just a wrapper around basic File IO methods.
    def fetch_local_image(filename)
      filename = ProductImport.settings[:product_image_path] + filename
      unless File.exists?(filename) && File.readable?(filename)
        log("Image #{filename} was not found on the server, so this image was not imported.", :warn)
        return nil
      else
        return File.open(filename, 'rb')
      end
    end


    #This method can be used when the filename matches the format of a URL.
    # It uses open-uri to fetch the file, returning a Tempfile object if it
    # is successful.
    # If it fails, it in the first instance logs the HTTP error (404, 500 etc)
    # If it fails altogether, it logs it and exits the method.
    def fetch_remote_image(filename)
      begin
        io = open(URI.parse(filename))
        def io.original_filename; base_uri.path.split('/').last; end
        return io
      rescue OpenURI::HTTPError => error
        log("Image #{filename} retrival returned #{error.message}, so this image was not imported")
      rescue => error
        log("Image #{filename} could not be downloaded, so was not imported. #{error.message}")
      end
    end

    ### TAXON HELPERS ###

    # associate_product_with_taxon
    # This method accepts three formats of taxon hierarchy strings which will
    # associate the given products with taxons:
    # 1. A string on it's own will will just find or create the taxon and
    # add the product to it. e.g. taxonomy = "Category", taxon_hierarchy = "Tools" will
    # add the product to the 'Tools' category.
    # 2. A item > item > item structured string will read this like a tree - allowing
    # a particular taxon to be picked out
    # 3. An item > item & item > item will work as above, but will associate multiple
    # taxons with that product. This form should also work with format 1.
    def associate_product_with_taxon(product, taxonomy, taxon_hierarchy)
      return if product.nil? || taxonomy.nil? || taxon_hierarchy.nil?
      #Using find_or_create_by_name is more elegant, but our magical params code automatically downcases
      # the taxonomy name, so unless we are using MySQL, this isn't going to work.
      
      taxonomy_name = taxonomy
      taxonomy = Taxonomy.find(:first, :conditions => ["lower(name) = ?", taxonomy])
      taxonomy = Taxonomy.create(:name => taxonomy_name.capitalize) if taxonomy.nil? && ProductImport.settings[:create_missing_taxonomies]

      taxon_hierarchy.split(/\s*\&\s*/).each do |hierarchy|
        hierarchy = hierarchy.split(/\s*>\s*/)
        last_taxon = taxonomy.root

        if hierarchy.count > 1
          hierarchy.shift
          hierarchy.each do |taxon|
            last_taxon = last_taxon.children.find_or_create_by_name_and_taxonomy_id(taxon, taxonomy.id)
          end
        end
            
        #Spree only needs to know the most detailed taxonomy item
        product.taxons << last_taxon unless product.taxons.include?(last_taxon)
      end

    end
    ### END TAXON HELPERS ###

    # May be implemented via decorator if useful:
    #
    #    Spree::ProductImport.class_eval do
    #
    #      private
    #
    #      def after_product_built(product, params_hash)
    #        # so something with the product
    #      end
    #    end
    def after_product_built(product, params_hash)
    end
  end
end
