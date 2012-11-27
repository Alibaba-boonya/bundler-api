require_relative '../spec_helper'
require_relative '../support/gemspec_helper'
require_relative '../../lib/bundler_api/update/gem_db_helper'
require_relative '../../lib/bundler_api/gem_helper'

describe BundlerApi::GemDBHelper do
  let(:db)        { Sequel.connect(ENV['TEST_DATABASE_URL']) }
  let(:gem_cache) { Hash.new }
  let(:mutex)     { nil }
  let(:helper)    { BundlerApi::GemDBHelper.new(db, gem_cache, mutex) }
  around(:each) do |example|
    db.transaction(:rollback => :always) { example.run }
  end

  describe "#gem_exists?" do
    let(:payload) { BundlerApi::GemHelper.new("foo", Gem::Version.new("1.0"), "ruby", false) }

    context "if the gem exists" do
      before do
        rubygem = db[:rubygems].insert(name: "foo")
        version = db[:versions].insert(rubygem_id: rubygem, number: "1.0", platform: "ruby", indexed: true)
      end

      it "returns the rubygems and versions id" do
        result = helper.exists?(payload)

        expect(result[:rubygem_id]).to be_true
        expect(result[:version_id]).to be_true
      end
    end

    context "if the gem does not exst" do
      it "returns nil" do
        expect(helper.exists?(payload)).to be_nil
      end
    end
  end

  describe "#find_or_insert_rubygem" do
    include GemspecHelper

    let(:name) { "foo" }
    let(:version) { "1.0" }
    let(:spec) { generate_gemspec(name, version) }

    context "when there is no exisitng rubygem" do
      it "should insert the rubygem" do
        insert, rubygem_id = helper.find_or_insert_rubygem(spec)

        expect(insert).to eq(true)
        expect(db[:rubygems].filter(name: spec.name).select(:id).first[:id]).to eq(rubygem_id)
      end
    end

    context "when the rubygem already exists" do
      before do
        @rubygem_id = db[:rubygems].insert(name: name)
      end

      it "should retrieve the existing rubygem" do
        insert, rubygem_id = helper.find_or_insert_rubygem(spec)

        expect(insert).to eq(false)
        expect(rubygem_id).to eq(@rubygem_id)
      end
    end
  end

  describe "#find_or_insert_version" do
    include GemspecHelper

    let(:name)     { "foo" }
    let(:version)  { "1.0" }
    let(:platform) { "ruby" }
    let(:indexed)  { true }
    let(:spec)     { generate_gemspec(name, version, platform) }

    before do
      @rubygem_id = helper.find_or_insert_rubygem(spec).last
    end

    context "when there is no existing version" do
      it "should insert the version" do
        insert, version_id = helper.find_or_insert_version(spec, @rubygem_id, platform, indexed)

        expect(insert).to eq(true)
        expect(version_id).to eq(db[:versions].filter(rubygem_id: @rubygem_id,
                                                      number:     version,
                                                      platform:   platform,
                                                      indexed:    indexed).
                                                      select(:id).first[:id])
      end

      context "when the platform in the index differs from the spec" do
        let(:platform) { "jruby" }
        let(:spec)     { generate_gemspec(name, version, "java") }

        it "inserts the platform from the index and not the spec" do
          insert, version_id = helper.find_or_insert_version(spec, @rubygem_id, platform, indexed)

          expect(insert).to eq(true)
          expect(version_id).to eq(db[:versions].filter(rubygem_id: @rubygem_id,
                                                        number:     version,
                                                        platform:   platform,
                                                        indexed:    indexed).
                                                        select(:id).first[:id])
        end
      end

      context "when indexed is nil" do
        let(:indexed) { nil }

        it "automatically indexes it" do
          insert, version_id = helper.find_or_insert_version(spec, @rubygem_id, platform, indexed)

          expect(insert).to eq(true)
          expect(version_id).to eq(db[:versions].filter(rubygem_id: @rubygem_id,
                                                        number:     version,
                                                        platform:   platform,
                                                        indexed:    true).
                                                        select(:id).first[:id])
        end
      end
    end

    context "when the version exists" do
      before do
        @version_id = db[:versions].insert(rubygem_id: @rubygem_id,
                                           number:     version,
                                           platform:   platform,
                                           indexed:    indexed)
      end

      it "finds the existing version" do
        insert, version_id = helper.find_or_insert_version(spec, @rubygem_id, platform)

        expect(insert).to eq(false)
        expect(version_id).to eq(@version_id)
      end

      context "when the version is not indexed" do
        let(:indexed) { false }

        it "updates the indexed value" do
          insert, version_id = helper.find_or_insert_version(spec, @rubygem_id, platform, true)

          expect(db[:versions].filter(id: @version_id).select(:indexed).first[:indexed]).to eq(true)
        end

        it "does not update the indexed value" do
          insert, version_id = helper.find_or_insert_version(spec, @rubygem_id, platform, nil)

          expect(db[:versions].filter(id: @version_id).select(:indexed).first[:indexed]).to eq(false)
        end
      end
    end
  end

  describe "#insert_dependencies" do
    include GemspecHelper

    context "when the dep gem already exists" do
      let(:requirement) { "~> 1.0" }
      let(:foo_spec)    { generate_gemspec('foo', '1.0') }
      let(:bar_spec)    { generate_gemspec('bar', '1.0') }

      before do
        @bar_rubygem_id = helper.find_or_insert_rubygem(bar_spec).last
        foo_rubygem_id  = helper.find_or_insert_rubygem(foo_spec).last
        @foo_version_id = helper.find_or_insert_version(foo_spec, foo_rubygem_id).last
      end

      it "should insert the dependencies" do
        helper.insert_dependencies(foo_spec, @foo_version_id)

        expect(db[:dependencies].filter(requirements: requirement,
                                        scope:        'runtime',
                                        rubygem_id:   @bar_rubygem_id,
                                        version_id:   @foo_version_id).count).to eq(1)
      end

      context "sometimes the dep is an array" do
        let(:foo_spec) do
          spec = generate_gemspec('foo', '1.0')
          spec.extend(Module.new {
            def dependencies
              [["bar", "~> 1.0"]]
            end
          })

          spec
        end

        it "should insert the dependencies" do
          helper.insert_dependencies(foo_spec, @foo_version_id)

          expect(db[:dependencies].filter(requirements: requirement,
                                          scope:        'runtime',
                                          rubygem_id:   @bar_rubygem_id,
                                          version_id:   @foo_version_id).count).to eq(1)
        end
      end

      context "when the dep db record exists" do
        before do
          db[:dependencies].insert(
            requirements: requirement,
            rubygem_id:   @bar_rubygem_id,
            version_id:   @foo_version_id,
            scope:        'runtime'
          )
        end

        it "should just skip adding it" do
          helper.insert_dependencies(foo_spec, @foo_version_id)

          expect(db[:dependencies].filter(requirements: requirement,
                                          scope:        'runtime',
                                          rubygem_id:   @bar_rubygem_id,
                                          version_id:   @foo_version_id).count).to eq(1)
        end
      end
    end
  end
end