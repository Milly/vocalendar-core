require 'spec_helper'

describe "histories/index" do
  before(:each) do
    assign(:histories, [
      stub_model(History,
        :target => "Target",
        :target_type => "Target Type",
        :target_id => 1,
        :action => "Action",
        :user_id => 2,
        :note => "MyText"
      ),
      stub_model(History,
        :target => "Target",
        :target_type => "Target Type",
        :target_id => 1,
        :action => "Action",
        :user_id => 2,
        :note => "MyText"
      )
    ])
  end

  it "renders a list of histories" do
    render
    # Run the generator again with the --webrat flag if you want to use webrat matchers
    assert_select "tr>td", :text => "Target".to_s, :count => 2
    assert_select "tr>td", :text => 1.to_s, :count => 2
    assert_select "tr>td", :text => "Action".to_s, :count => 2
    assert_select "tr>td", :text => 2.to_s, :count => 2
    assert_select "tr>td", :text => "MyText".to_s, :count => 2
  end
end
