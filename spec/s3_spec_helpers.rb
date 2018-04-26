module S3SpecHelpers
  def delete_s3_test_files
    client = Aws::S3::Client.new(
      access_key_id: ENV['s3_access_key_id'],
      region: ENV['s3_region'],
      secret_access_key: ENV['s3_secret_access_key']
    )

    bucket = Aws::S3::Bucket.new(ENV['s3_bucket_name'], client: client)
    bucket.objects(prefix: ENV['s3_key_prefix']).batch_delete!
  end
end