#!/usr/bin/env ruby
# Build-time only. Fetch the approved signing profile without cloud-signing access.
require 'base64'
require 'json'
require 'net/http'
require 'openssl'

module PlacesTestFlightProfile
  def self.token(key_path, key_id, issuer_id, now: Time.now.to_i)
    encode = ->(value) { Base64.urlsafe_encode64(value, padding: false) }
    header = { alg: 'ES256', kid: key_id, typ: 'JWT' }
    claims = { iss: issuer_id, iat: now, exp: now + 300, aud: 'appstoreconnect-v1' }
    content = [header, claims].map { |value| encode.call(JSON.generate(value)) }.join('.')
    key = OpenSSL::PKey.read(File.read(key_path))
    raise 'Expected a P-256 App Store Connect key' unless key.is_a?(OpenSSL::PKey::EC) && key.group.curve_name == 'prime256v1'
    signature = OpenSSL::ASN1.decode(key.sign('SHA256', content)).value
                       .map { |integer| integer.value.to_s(2).rjust(32, "\0") }.join
    raise 'Invalid ES256 signature length' unless signature.bytesize == 64
    content + '.' + encode.call(signature)
  end

  def self.download(env, destination)
    profile_id = env.fetch('PLACES_PROFILE_ID')
    raise 'Invalid profile ID' unless /\A[A-Z0-9]+\z/.match?(profile_id)
    uri = URI('https://api.appstoreconnect.apple.com/v1/profiles/' + profile_id)
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = 'Bearer ' + token(env.fetch('ASC_KEY_PATH'), env.fetch('ASC_KEY_ID'), env.fetch('ASC_ISSUER_ID'))
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) { |http| http.request(request) }
    raise "Apple profile download failed (HTTP #{response.code}); check API key and profile access" unless response.code == '200'
    data = JSON.parse(response.body).fetch('data')
    raise 'Apple returned an unexpected signing profile' unless data.fetch('id') == profile_id && data.fetch('attributes').fetch('profileType') == 'IOS_APP_STORE'
    File.binwrite(destination, Base64.strict_decode64(data.fetch('attributes').fetch('profileContent')))
    File.chmod(0600, destination)
    puts 'Downloaded the configured App Store signing profile.'
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    PlacesTestFlightProfile.download(ENV, ARGV.fetch(0))
  rescue StandardError => error
    # Do not print HTTP responses, tokens or private keys.
    detail = error.instance_of?(RuntimeError) ? error.message : error.class.to_s
    warn "Signing profile setup failed: #{detail}"
    exit 1
  end
end
