class ImportsWorker
  include Sidekiq::Worker
  # sidekiq_options queue: "high"
  # sidekiq_options retry: false
  
  def perform(product_import_id, user_id)
    begin
      product_import = Spree::ProductImport.find(product_import_id)
      results = product_import.import_data!(Spree::ProductImport.settings[:transaction])
      Spree::UserMailer.product_import_results(Spree::User.find(user_id)).deliver
    rescue Exception => exp
      Spree::UserMailer.product_import_results(Spree::User.find(user_id), exp.message).deliver
    end
  end
end