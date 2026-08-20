# frozen_string_literal: true

require_relative "../test_helper"

module Parser
  class AnalyzeOptionTest < Minitest::Spec
    include SnapshotUtils

    test "analyze enabled by default transforms ERB nodes" do
      assert_parsed_snapshot(<<~HTML)
        <% if true %>
        <% end %>
      HTML
    end

    test "analyze disabled skips ERB node transformation" do
      assert_parsed_snapshot(<<~HTML, analyze: false)
        <% if true %>
        <% end %>
      HTML
    end

    test "analyze :compile transforms ERB nodes and matches HTML tags like analyze: true" do
      assert_parsed_snapshot(<<~HTML, analyze: :compile)
        <% if true %>
        <% end %>
      HTML
    end

    test "analyze :compile skips diagnostics but still nests HTML elements" do
      html = "<div><p>hello <span>world</span></p></div>"

      compiled = Herb.parse(html, analyze: :compile)
      full = Herb.parse(html, analyze: true)

      assert_instance_of Herb::AST::HTMLElementNode, compiled.value.children.first
      assert_equal full.value.inspect, compiled.value.inspect
    end

    test "analyze :compile round-trips through parser_options" do
      result = Herb.parse("<div></div>", analyze: :compile)

      assert_equal :compile, result.options.analyze
    end

    test "analyze with an unknown symbol raises ArgumentError" do
      assert_raises(ArgumentError) do
        Herb.parse("<div></div>", analyze: :bogus)
      end
    end
  end
end
