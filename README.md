# Zorki

Welcome to your new gem! In this directory, you'll find the files you need to be able to package up your Ruby library into a gem. Put your Ruby code in the file `lib/zorki`. To experiment with that code, run `bin/console` for an interactive prompt.

TODO: Delete this and the text above, and describe your gem

## Pre Reqs

This requires the chromedriver

### MacOS

`brew install chromedriver`

### Raspberry OS (aka Rasbian / Debian)
Since this requires ARMHF support it's not through regular sources. However, the maintainers of Raspberry OS has made their own!
`sudo apt install chromium-chromedriver`

### Debian/Ubuntu
`sudo apt install chromedriver` (should work)

## Installation

Add this line to your application's Gemfile:

```ruby
gem "zorki"
```

And then execute:

    $ bundle install


### Selenium Standalone
We use Selenium's standalone package. To set it up:
1. Download the "Selenium Server (Grid)" JAR package at https://www.selenium.dev/downloads/
1. Save it to the folder of this package
1. Test that it works by running `java -jar ./selenium-server-4.2.1.jar standalone` (note the actual version you downloaded)

## Testing

1. Turn on the Selenium server `java -jar ./selenium-server-4.2.1.jar standalone` in a separate pane or window
1. `rake test`

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Debugging

This scraper is prone to break pretty often due to Instagram's GraphQL schema being pretty damn unstable.
Whether this is malevolent (to purposely break scrapers) or just happening in the course of development is undetermined and really, doesn't matter.

Debugging this is a bit of a pain, but I'm laying out a few steps to start at and make this easier.
Some of this may sound basic, but it's good to keep it all in mind.

1. Run the tests `rake test` and note the line where everything is breaking, if it's a schema change
   this will probably be the same line a few times over. If it's a lot of different lines it's probably
   your code, not on the Instagram side.
1. Set a debug point around the `find_graphql_script` function start in `lib/zorki/scrapers/scraper.rb` file
   (line 27 as of writing).
1. You can also add a begin/rescue block around the find functions looking for the GraphQL blob.
1. When the debugger is hit the Chrome instance will be on the page that's causing the issue, from there
   you can inspect the page itself, looking for the keywords.
1. From this point, start fiddling in the debugger, traversing the DOM until you get to a place that looks
   like it might be the right structure.
1. Fix up the find functions (sometimes a reordering of the look ups is enough)
1. Trust the tests, run them over and over, modifying as little about the rest of the code as possible,
   otherwise you may end up changing the structure of everything, we don't want that.
1. Ask Chris or Asa if you have questions.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/zorki. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/[USERNAME]/zorki/blob/master/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Zorki project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/[USERNAME]/zorki/blob/master/CODE_OF_CONDUCT.md).
