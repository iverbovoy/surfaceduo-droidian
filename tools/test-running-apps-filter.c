/* SPDX-License-Identifier: MIT */
#include "running-apps-filter.h"

int main (void)
{
  g_autoptr (GHashTable) open = g_hash_table_new (g_str_hash, g_str_equal);
  g_autoptr (GVariant) follows = g_variant_ref_sink (g_variant_parse (
    G_VARIANT_TYPE ("a{ss}"),
    "{'org.gnome.Settings': 'org.sfduo.Settings', "
    "'mobi.phosh.MobileSettings': 'org.sfduo.Settings', "
    "'self': 'self', 'empty': ''}", NULL, NULL, NULL));
  g_autoptr (GVariant) wrong = g_variant_ref_sink (g_variant_new_string ("wrong type"));

  /* A saved relation without an open leader must never hide a standalone page. */
  g_assert_false (phosh_running_app_is_follower (follows, open, "org.gnome.Settings"));
  g_hash_table_add (open, "org.sfduo.Settings");
  g_assert_true (phosh_running_app_is_follower (follows, open, "org.gnome.Settings"));
  g_assert_true (phosh_running_app_is_follower (follows, open, "mobi.phosh.MobileSettings"));
  g_assert_false (phosh_running_app_is_follower (follows, open, "org.sfduo.Settings"));
  g_assert_false (phosh_running_app_is_follower (follows, open, "org.gnome.Calculator"));

  /* No dock, an older dock, a bad property and a late app_id are all fail-open. */
  g_assert_false (phosh_running_app_is_follower (NULL, open, "org.gnome.Settings"));
  g_assert_false (phosh_running_app_is_follower (wrong, open, "org.gnome.Settings"));
  g_assert_false (phosh_running_app_is_follower (follows, open, NULL));
  g_assert_false (phosh_running_app_is_follower (follows, open, ""));
  g_hash_table_add (open, "self");
  g_hash_table_add (open, "");
  g_assert_false (phosh_running_app_is_follower (follows, open, "self"));
  g_assert_false (phosh_running_app_is_follower (follows, open, "empty"));

  /* Closing and reopening the leader reclassifies the same surviving page. */
  g_hash_table_remove (open, "org.sfduo.Settings");
  g_assert_false (phosh_running_app_is_follower (follows, open, "org.gnome.Settings"));
  g_hash_table_add (open, "org.sfduo.Settings");
  g_assert_true (phosh_running_app_is_follower (follows, open, "org.gnome.Settings"));
  g_print ("PASS: running-apps follower visibility\n");
  return 0;
}
