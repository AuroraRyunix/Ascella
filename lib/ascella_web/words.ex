defmodule AscellaWeb.Words do
  @moduledoc """
  What went wrong, in a sentence a person in a playing hall can act on.
  The reasons come from `Ascella.Installer` and friends; anything not named
  here is shown as it is, which is ugly and honest.
  """
  use Gettext, backend: AscellaWeb.Gettext

  def action(:install), do: gettext("Installing")
  def action(:update), do: gettext("Updating")
  def action(:start), do: gettext("Starting")
  def action(:stop), do: gettext("Stopping")
  def action(:rollback), do: gettext("Going back")
  def action(:uninstall), do: gettext("Removing")
  def action(:queued), do: gettext("Waiting its turn")

  def launcher(:start_menu), do: gettext("In the Start menu")
  def launcher(:desktop), do: gettext("On the Desktop")
  def launcher(:dock), do: gettext("Keep in the Dock")
  def launcher(:login), do: gettext("Open at login")
  def launcher(:menu), do: gettext("In the applications menu")
  def launcher(:favourites), do: gettext("Among the favourites")

  def offer([:start_menu]), do: gettext("Yes, put it in the Start menu")
  def offer([:dock]), do: gettext("Yes, keep it in the Dock")
  def offer(_menu), do: gettext("Yes, put it in the applications menu")

  def error({_action, reason}), do: reason(reason)

  @doc "Like `error/1`, with the app at hand for the sentences that name it."
  def error({_action, {:running, _name}}, %{name: name}), do: reason({:running, name})
  def error(error, _app), do: error(error)

  def reason(:no_release), do: gettext("No release is known yet. Check for updates first.")

  def reason(:no_checksums),
    do: gettext("This release publishes no checksums, so nothing was installed.")

  def reason(:not_in_checksums),
    do: gettext("The file is not in the release's checksums, so it was not used.")

  def reason({:checksum_mismatch, _expected, _actual}),
    do: gettext("The download does not match its checksum. Nothing was changed.")

  def reason({:redirect_refused, _url}),
    do: gettext("The download was sent somewhere other than GitHub, and was refused.")

  def reason({:offline, _}), do: gettext("GitHub could not be reached. Nothing was changed.")

  def reason({:http, status}),
    do: gettext("GitHub answered %{status}. Nothing was changed.", status: status)

  def reason(:not_found), do: gettext("The release has no file for this computer.")

  def reason({:running, name}),
    do: gettext("%{name} is open. Close %{name} first, then update.", name: name)

  def reason({:timeout, program}),
    do:
      gettext(
        "%{program} did not answer in time, so Ascella gave up waiting. Nothing was changed after that point; try again.",
        program: program
      )

  def reason(:no_rollback),
    do:
      gettext(
        "There is no way back for this program: updating changes its database, and an older version cannot read that."
      )

  def reason(:did_not_stop),
    do:
      gettext(
        "It did not stop within a minute, so it was left as it was. Stop it yourself, then try again."
      )

  def reason(:no_window),
    do: gettext("Its window could not be found to close it. Stop it yourself, then try again.")

  def reason(:per_machine),
    do:
      gettext(
        "It is installed for everyone on this PC. Update it with the .msi, as an administrator."
      )

  def reason({:install_folder_holds_data, folder, file}),
    do:
      gettext(
        "Refused: %{file} lies in the install folder %{folder}, which an update may remove. Move the data out first.",
        file: file,
        folder: folder
      )

  def reason({:data_dir, app, dir}),
    do: gettext("Refused: that would touch %{dir}, the data of %{app}.", dir: dir, app: app)

  def reason(:needs_run_as),
    do:
      gettext(
        "Ascella runs as root and will not start apps as root. Set ASCELLA_RUN_AS to a user."
      )

  def reason(:already_there),
    do: gettext("Something with that name is already there, not made by Ascella. Left alone.")

  def reason(:not_offered), do: gettext("That is not possible on this computer.")
  def reason(:nothing_to_launch), do: gettext("There is nothing to start from a shortcut.")
  def reason(:not_made), do: gettext("The shortcut was not made.")

  def reason({:not_ours, path}),
    do: gettext("Not removed: %{path} is not in a folder Ascella makes shortcuts in.", path: path)

  def reason(:per_machine_remove),
    do:
      gettext(
        "It is installed for everyone on this PC. Remove it with the .msi, as an administrator."
      )

  def reason(:not_removed),
    do: gettext("Its uninstaller ran, but the program is still there. Look again in a minute.")

  def reason(:no_previous), do: gettext("There is no previous version to go back to.")
  def reason(:not_supported), do: gettext("Going back is not possible for this kind of install.")
  def reason(:already_installed), do: gettext("That version is already installed.")
  def reason(:absent), do: gettext("It is not installed.")
  def reason(:no_build), do: gettext("There is no build for this computer.")
  def reason(:no_local_app_data), do: gettext("Windows did not say where LOCALAPPDATA is.")

  def reason({:wrong_version, _found, _wanted}),
    do: gettext("The download holds another version than its release says.")

  def reason({:no_writable_folder, _}),
    do: gettext("No Applications folder here can be written to.")

  def reason(:changed_after_download),
    do: gettext("The download changed after it was checked, and was not run.")

  def reason({:exit, program, status, _output}),
    do: gettext("%{program} stopped with code %{status}.", program: program, status: status)

  def reason(other) when is_binary(other), do: other
  def reason(other), do: inspect(other)

  def latest_error(:no_release), do: gettext("Nothing published yet")
  def latest_error(_other), do: gettext("Could not ask GitHub")
end
