/**
 * Copyright (C) 2011 Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

I18n.scoped('groups', function(I18n) {
  $(document).ready(function() {
    $(".add_group_link").click(function(event) {
      event.preventDefault();
      $("#add_group_form").slideDown(function() {
        $("html,body").scrollTo($("#add_group_form"));
      });
    });
    $("#add_group_form .cancel_button").click(function() {
      $("#add_group_form").slideUp();
    });
    $("#add_group_form").formSubmit({
      beforeSubmit: function(data) {
        $(this).loadingImage();
        $(this).find(".submit_button").text(I18n.t('messages.creating_group', 'Creating Group...')).attr('disabled', true);
      },
      success: function(data) {
        $(this).loadingImage('remove');
        $(this).find(".submit_button").text(I18n.t('buttons.create_group', 'Create Group')).attr('disabled', false);
        $(this).slideUp();
        var $group = $("#group_blank").clone(true);
        $group.fillTemplateData({
          data: data.group || data.course_assigned_group,
          hrefValues: ['id']
        });
        $("#group_blank").before($group.show());
        $("html,body").scrollTo($group);
        $group.animate({'backgroundColor': '#FFEE88'}, 1000)
            .animate({'display': 'block'}, 2000)
            .animate({'backgroundColor': '#FFFFFF'}, 2000, function() {
              $(this).css('backgroundColor', '');
            });
      },
      error: function(data) {
        $(this).find(".submit_button").text(I18n.t('errors.creating_group_failed', 'Creating Group Failed')).attr('disabled', false);
        $(this).loadingImage('remove');
      }
    });
    $(".toggle_members_link").click(function(event) {
      event.preventDefault();
      event.stopPropagation();
      var $group = $(this).parents('li.group');
      var $member_list = $group.find('ul.member_list');
      if ($member_list.length) {
        if ($member_list.is(":visible")) {
          $member_list.hide();
          $(this).prop('title', I18n.t('member_tooltip_show', 'View group roster'));
        } else {
          $member_list.show();
          $(this).prop('title', I18n.t('member_tooltip_hide', 'Hide group roster'));
        }
        return;
      }
      $member_list = $('<ul/>').addClass('member_list');
      var $loader = $('<li/>').addClass('loader').html(I18n.t('loading', 'loading group roster...'));
      $member_list.append($loader);
      $member_list.pageless({
        container: $member_list,
        currentPage: 0,
        totalPages: 1,
        url: $(this).prop('href') + '.json',
        loader: $loader,
        animate: false,
        scrape: function(data, xhr) {
          students = JSON.parse(data)
          for (idx in students) {
            $('<li/>').addClass('student').html(students[idx].display_name).insertBefore($loader);
          }
          return '';
        }
      });
      $group.append($member_list);
      $member_list.show();
      $(this).prop('title', I18n.t('member_tooltip_hide', 'Hide group roster'));
    });
  });
});
