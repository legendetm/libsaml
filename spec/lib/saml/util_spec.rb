require 'spec_helper'

class ServiceProvider
  include Saml::Provider

  def initialize
    @entity_descriptor = Saml::Elements::EntityDescriptor.parse(File.read("spec/fixtures/metadata/service_provider.xml"))
    @private_key       = OpenSSL::PKey::RSA.new(File.read("spec/fixtures/key.pem"))
  end
end

describe Saml::Util do
  let(:service_provider) { ServiceProvider.new }
  let(:message) { FactoryGirl.build :authn_request, issuer: service_provider.entity_id }
  let(:signed_message) { "signed xml" }

  describe ".sign_xml" do
    it "calls add_signature on the specified message" do
      message.should_receive(:add_signature)
      described_class.sign_xml message
    end

    it "creates a new signed document" do
      Xmldsig::SignedDocument.should_receive(:new).with(any_args).and_return stub.as_null_object
      described_class.sign_xml message
    end

    context "when a block is given" do
      it "sign is called on the signed document, not on the provider" do
        message.provider.should_not_receive(:sign)
        Xmldsig::SignedDocument.any_instance.should_receive(:sign).and_return signed_message

        described_class.sign_xml(message) do |data, signature_algorithm|
          service_provider.sign signature_algorithm, data
        end
      end
    end

    context "without specifiying a block" do
      it "sign is called on the provider of the specified message" do
        Xmldsig::SignedDocument.any_instance.should_receive(:sign).and_yield(stub, stub)
        message.provider.should_receive(:sign).and_return signed_message

        described_class.sign_xml message
      end
    end
  end

  describe ".post" do
    let(:location) { "http://example.com" }
    let(:post_request) { described_class.post location, message }

    before :each do
      HTTPI.stub(:post) do |request|
        @request = request
        stub(code: 200, body: message.to_xml)
      end
    end

    it "has an url" do
      post_request
      @request.url.to_s.should == location
    end

    it "has a body" do
      post_request
      @request.body.should == message
    end

    it "has a 'Content-Type' header" do
      post_request
      @request.headers["Content-Type"].should == "text/xml"
    end

    it "has a certificate" do
      post_request
      @request.auth.ssl.cert_file.should == Saml::Config::ssl_certificate_file
    end

    it "has a private key" do
      post_request
      @request.auth.ssl.cert_key_file.should == Saml::Config::ssl_private_key_file
    end

    it "posts the request" do
      HTTPI.should_receive(:post)
      post_request
    end
  end

  describe ".verify_xml" do
    let(:message) { Saml::Response.new(assertions: [Saml::Assertion.new.tap { |a| a.add_signature },
                                                    Saml::Assertion.new.tap { |a| a.add_signature }]) }
    let(:signed_xml) { Saml::Util.sign_xml(message) }

    it "verifies all the signatures in the file" do
      response = Saml::Response.parse(signed_xml)

      response.provider.should_receive(:verify).exactly(3).times.and_return(true)
      Saml::Util.verify_xml(response, signed_xml)
    end

    it "returns the signed message type" do
      malicious_response = Saml::Response.new(issuer: 'hacked')
      malicious_xml = "<hack>#{signed_xml}#{malicious_response.to_xml}</hack>"
      malicious_xml.gsub!("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n", '')
      response = Saml::Response.parse(malicious_xml, single: true)

      Saml::Util.verify_xml(response, malicious_xml).should be_a(Saml::Response)
    end
  end

  describe ".encrypt_assertion" do
    let(:encrypted_assertion) { Saml::Util.encrypt_assertion(Saml::Assertion.new.to_s, service_provider.private_key) }
    it "returns an encrypted assertion object" do
      encrypted_assertion.should be_a Saml::Elements::EncryptedAssertion
    end

    it "is not valid when with no encrypted data" do
      encrypted_assertion.encrypted_data = nil
      encrypted_assertion.should be_invalid
    end
  end
end
