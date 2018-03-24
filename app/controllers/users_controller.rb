class UsersController < ApplicationController
  helper PaginableHelper
  helper PermsHelper
  include ConditionalUserMailer
  after_action :verify_authorized
  respond_to :html

  ##
  # GET - List of all users for an organisation
  # Displays number of roles[was project_group], name, email, and last sign in
  def admin_index
    authorize User
    if current_user.can_super_admin?
      @users = User.page(1)
    else
      @users = current_user.org.users.page(1)
    end
  end

  ##
  # GET - Displays the permissions available to the selected user
  # Permissions which the user already has are pre-selected
  # Selecting new permissions and saving calls the admin_update_permissions action
  def admin_grant_permissions
    user = User.find(params[:id])
    authorize user
    
    # Super admin can grant any Perm, org admins can only grant Perms they
    # themselves have access to
    if current_user.can_super_admin?
      perms = Perm.all
    else
      perms = current_user.perms
    end

    render json: {
      "user" => {
        "id" => user.id,
        "html" => render_to_string(partial: 'users/admin_grant_permissions', 
                                   locals: { user: user, perms: perms }, 
                                   formats: [:html])
      }
    }.to_json
  end

  ##
  # POST - updates the permissions for a user
  # redirects to the admin_index action
  # should add validation that the perms given are current perms of the current_user
  def admin_update_permissions
    @user = User.find(params[:id])
    authorize @user
    perms_ids = params[:perm_ids].blank? ? [] : params[:perm_ids].map(&:to_i)
    perms = Perm.where( id: perms_ids)
    current_user.perms.each do |perm|
      if @user.perms.include? perm
        if ! perms.include? perm
          @user.perms.delete(perm)
          if perm.id == Perm.use_api.id
            @user.remove_token!
          end
        end
      else
        if perms.include? perm
          @user.perms << perm
          if perm.id == Perm.use_api.id
            @user.keep_or_generate_token!
          end
        end
      end
    end

    if @user.save!
      deliver_if(recipients: @user, key: 'users.admin_privileges') do |r|
        UserMailer.admin_privileges(r).deliver_now
      end
      render(json: {
        code: 1,
        msg: success_message(_('permissions'), _('saved')),
        current_privileges: render_to_string(partial: 'users/current_privileges', locals: { user: @user }, formats: [:html])
        })
    else
      render(json: { code: 0, msg: failed_update_error(@user, _('user')) })
    end
  end

  def update_email_preferences
    prefs = params[:prefs]
    authorize current_user, :update?
    pref = current_user.pref
    # does user not have prefs?
    if pref.blank?
      pref = Pref.new
      pref.settings = {}
      pref.user = current_user
    end
    pref.settings[:email] = booleanize_hash(prefs)
    pref.save

    # Include active tab in redirect path
    redirect_to "#{edit_user_registration_path}\#notification-preferences", notice: success_message(_('preferences'), _('saved'))
  end

  # PUT /users/:id/org_swap
  # -----------------------------------------------------
  def org_swap
    # Allows the user to swap their org affiliation on the fly
    authorize current_user
    begin
      org = Org.find(org_swap_params[:org_id])
    rescue ActiveRecord::RecordNotFound
      redirect_to(request.referer, alert: _('Please select an organisation from the list')) and return
    end
    if org.present?
      current_user.org = org
      if current_user.save!
        redirect_to request.referer, notice: _('Your organisation affiliation has been changed. You may now edit templates for %{org_name}.') % {org_name: current_user.org.name}
      else
        redirect_to request.referer, alert: _('Unable to change your organisation affiliation at this time.')
      end
    else
      redirect_to request.referer, alert: _('Unknown organisation.')
    end
  end

  # GET /users/:id/ldap_username
  def ldap_username
    skip_authorization
    render '/users/dmptool/ldap_username'
  end

  def ldap_account
    skip_authorization
    @user = User.where(ldap_username: params[:username]).first
    if @user.present?
      render(json: {
        code: 1,
        email: @user.email,
        msg: _("The DMPTool Account email associated with this username is #{@user.email}"),
      })
    else
      render(json: { 
        code: 0,
        email: '', 
        msg: _("We do not recognize the username %{username}. Please try again or contact us if you have forgotten the username and email for your existing DMPTool account.") % { username: params[:username] }
      })
    end
  end

  private
  def org_swap_params
    params.require(:user).permit(:org_id, :org_name)
  end
  
  ##
  # html forms return our boolean values as strings, this converts them to true/false
  def booleanize_hash(node)
    #leaf: convert to boolean and return
    #hash: iterate over leaves
    unless node.is_a?(Hash)
      return node == "true"
    end
    node.each do |key, value|
      node[key] = booleanize_hash(value)
    end
  end

end
