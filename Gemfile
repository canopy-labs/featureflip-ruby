source "https://rubygems.org"
gemspec

# railties -> irb -> rdoc pulls in rbs, and rbs 4.2 needs Ruby >= 3.3. CI tests from
# Ruby 3.2 (the gemspec floor), and the lockfile is resolved on a newer Ruby, so cap it.
gem "rbs", "< 4.2", require: false
