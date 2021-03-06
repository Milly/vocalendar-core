class ExLinksController < ApplicationController
  include VocalendarCore::HistoryUtils::Controller
  load_and_authorize_resource :except => :redirect

  def index
    @ex_links = @ex_links.page(params[:page]).per(50).order('id desc')
    params.has_key? :type and
      @ex_links = @ex_links.where(:type => params[:type].to_s)
    params[:q].blank? or
      @ex_links = @ex_links.search(params[:q])
    respond_with(@ex_links)
  end

  def show
    respond_with(@ex_link)
  end

  def new
    respond_with(@ex_link)
  end

  def edit
  end

  def create
    @ex_link.save
    @ex_link.errors.empty? and add_history
    respond_with(@ex_link)
  end

  def update
    @ex_link.update_attributes(update_params)
    @ex_link.errors.empty? and add_history
    respond_with(@ex_link)
  end

  def destroy
    @ex_link.destroy
    add_history
    respond_with(@ex_link)
  end

  def update_by_uri
    @ex_link.update_attributes_by_uri!
    respond_with(@ex_link)
  end

  def redirect
    @ex_link = ExLink.find params[:short_id].to_s.to_i(36)
    @ex_link.disabled? and raise ProcessError.new("This link has been disabled.", 410)
    begin
      ExLinkAccess.create({
                            :ex_link_id => @ex_link.id,
                            :ipaddr => request.remote_ip,
                            :user_agent => request.env['HTTP_USER_AGENT'].to_s[0..200],
                          }, :without_protection => true)
    rescue Exception => e
      logger.error "Failed to save access #{e.class.name}: #{e.message}"
    end
    redirect_to @ex_link.access_uri
  end
  
  private
  def update_params
    params.require(:ex_link).permit(:title, :disabled)
  end

  
  
end
