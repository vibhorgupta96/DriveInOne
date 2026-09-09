import 'package:flutter/material.dart';
import '../../../../domain/entities/account.dart';
import '../../../widgets/common/provider_icon.dart';

class AccountTile extends StatelessWidget {
  final AccountEntity account;
  final VoidCallback? onUnlink;

  const AccountTile({super.key, required this.account, this.onUnlink});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: ProviderIcon(providerType: account.providerType, size: 36),
      title: Text(account.email),
      subtitle: Text(account.providerType.displayName),
      trailing: IconButton(
        icon: Icon(Icons.link_off, color: Theme.of(context).colorScheme.error),
        onPressed: onUnlink,
        tooltip: 'Unlink account',
      ),
    );
  }
}
