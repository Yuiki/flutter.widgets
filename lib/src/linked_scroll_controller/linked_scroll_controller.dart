// Copyright 2018 the Dart project authors.
//
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file or at
// https://developers.google.com/open-source/licenses/bsd

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Sets up a collection of scroll controllers that mirror their movements to
/// each other.
///
/// Controllers are added and returned via [addAndGet]. The initial offset
/// of the newly created controller is synced to the current offset.
/// Controllers must be `dispose`d when no longer in use to prevent memory
/// leaks and performance degradation.
///
/// If controllers are disposed over the course of the lifetime of this
/// object the corresponding scrollables should be given unique keys.
/// Without the keys, Flutter may reuse a controller after it has been disposed,
/// which can cause the controller offsets to fall out of sync.
class LinkedScrollControllerGroup {
  final List<_LinkedScrollController> _allControllers = [];

  /// Creates a new controller that is linked to any existing ones.
  ScrollController addAndGet() {
    final initialScrollOffset = _attachedControllers.isEmpty
        ? 0.0
        : _attachedControllers.first.position.pixels;
    final controller =
        _LinkedScrollController(this, initialScrollOffset: initialScrollOffset);
    _allControllers.add(controller);
    return controller;
  }

  Iterable<_LinkedScrollController> get _attachedControllers =>
      _allControllers.where((controller) => controller.hasClients);

  /// Resets the scroll position of all linked controllers to 0.
  void resetScroll() {
    for (final controller in _attachedControllers) {
      controller.jumpTo(0.0);
    }
  }
}

/// A scroll controller that mirrors its movements to a peer, which must also
/// be a [_LinkedScrollController].
class _LinkedScrollController extends ScrollController {
  final LinkedScrollControllerGroup _controllers;

  _LinkedScrollController(this._controllers, {double initialScrollOffset})
      : super(initialScrollOffset: initialScrollOffset);

  @override
  void dispose() {
    _controllers._allControllers.remove(this);
    super.dispose();
  }

  @override
  void attach(ScrollPosition position) {
    assert(
        position is _LinkedScrollPosition,
        '_LinkedScrollControllers can only be used with'
        ' _LinkedScrollPositions.');
    final _LinkedScrollPosition linkedPosition = position;
    assert(linkedPosition.owner == this,
        '_LinkedScrollPosition cannot change controllers once created.');
    super.attach(position);
  }

  @override
  _LinkedScrollPosition createScrollPosition(ScrollPhysics physics,
      ScrollContext context, ScrollPosition oldPosition) {
    return _LinkedScrollPosition(
      this,
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      oldPosition: oldPosition,
    );
  }

  @override
  _LinkedScrollPosition get position => super.position;

  Iterable<_LinkedScrollController> get _allPeersWithClients =>
      _controllers._attachedControllers.where((peer) => peer != this);

  bool get canLinkWithPeers => _allPeersWithClients.isNotEmpty;

  Iterable<_LinkedScrollActivity> linkWithPeers(_LinkedScrollPosition driver) {
    assert(canLinkWithPeers);
    return _allPeersWithClients
        .map((peer) => peer.link(driver))
        .expand((e) => (e));
  }

  Iterable<_LinkedScrollActivity> link(_LinkedScrollPosition driver) {
    assert(hasClients);
    final activities = <_LinkedScrollActivity>[];
    for (_LinkedScrollPosition position in positions) {
      activities.add(position.link(driver));
    }
    return activities;
  }
}

// Implementation details: Whenever position.setPixels or position.forcePixels
// is called on a _LinkedScrollPosition (which may happen programmatically, or
// as a result of a user action),  the _LinkedScrollPosition creates a
// _LinkedScrollActivity for each linked position and uses it to move to or jump
// to the appropriate offset.
//
// When a new activity begins, the set of peer activities is cleared.
class _LinkedScrollPosition extends ScrollPositionWithSingleContext {
  _LinkedScrollPosition(
    this.owner, {
    ScrollPhysics physics,
    ScrollContext context,
    double initialPixels,
    ScrollPosition oldPosition,
  }) : super(
          physics: physics,
          context: context,
          initialPixels: initialPixels,
          oldPosition: oldPosition,
        ) {
    assert(owner != null);
  }

  final _LinkedScrollController owner;

  final Set<_LinkedScrollActivity> _peerActivities = <_LinkedScrollActivity>{};

  // We override hold to propagate it to all peer controllers.
  @override
  ScrollHoldController hold(VoidCallback holdCancelCallback) {
    for (final controller in owner._allPeersWithClients) {
      controller.position._holdInternal();
    }
    return super.hold(holdCancelCallback);
  }

  // Calls hold without propagating to peers.
  void _holdInternal() {
    // TODO: passing null to hold seems fishy, but it doesn't
    // appear to hurt anything. Revisit this if bad things happen.
    super.hold(null);
  }

  @override
  void beginActivity(ScrollActivity newActivity) {
    if (newActivity == null) {
      return;
    }
    for (_LinkedScrollActivity activity in _peerActivities) {
      activity.unlink(this);
    }

    _peerActivities.clear();

    super.beginActivity(newActivity);
  }

  @override
  double setPixels(double newPixels) {
    if (newPixels == pixels) {
      return 0.0;
    }
    updateUserScrollDirection(newPixels - pixels > 0.0
        ? ScrollDirection.forward
        : ScrollDirection.reverse);

    if (owner.canLinkWithPeers) {
      _peerActivities.addAll(owner.linkWithPeers(this));
      for (_LinkedScrollActivity activity in _peerActivities) {
        activity.moveTo(newPixels);
      }
    }

    return setPixelsInternal(newPixels);
  }

  double setPixelsInternal(double newPixels) {
    return super.setPixels(newPixels);
  }

  @override
  void forcePixels(double value) {
    if (value == pixels) {
      return;
    }
    updateUserScrollDirection(value - pixels > 0.0
        ? ScrollDirection.forward
        : ScrollDirection.reverse);

    if (owner.canLinkWithPeers) {
      _peerActivities.addAll(owner.linkWithPeers(this));
      for (_LinkedScrollActivity activity in _peerActivities) {
        activity.jumpTo(value);
      }
    }

    forcePixelsInternal(value);
  }

  void forcePixelsInternal(double value) {
    super.forcePixels(value);
  }

  _LinkedScrollActivity link(_LinkedScrollPosition driver) {
    if (this.activity is! _LinkedScrollActivity) {
      beginActivity(_LinkedScrollActivity(this));
    }
    final _LinkedScrollActivity activity = this.activity;
    activity.link(driver);
    return activity;
  }

  void unlink(_LinkedScrollActivity activity) {
    _peerActivities.remove(activity);
  }

  // We override this method to make it public (overridden method is protected)
  @override
  void updateUserScrollDirection(ScrollDirection value) {
    super.updateUserScrollDirection(value);
  }

  @override
  void debugFillDescription(List<String> description) {
    super.debugFillDescription(description);
    description.add('owner: $owner');
  }
}

class _LinkedScrollActivity extends ScrollActivity {
  _LinkedScrollActivity(_LinkedScrollPosition delegate) : super(delegate);

  @override
  _LinkedScrollPosition get delegate => super.delegate;

  final Set<_LinkedScrollPosition> drivers = <_LinkedScrollPosition>{};

  void link(_LinkedScrollPosition driver) {
    drivers.add(driver);
  }

  void unlink(_LinkedScrollPosition driver) {
    drivers.remove(driver);
    if (drivers.isEmpty) {
      delegate?.goIdle();
    }
  }

  @override
  bool get shouldIgnorePointer => true;

  @override
  bool get isScrolling => true;

  // _LinkedScrollActivity is not self-driven but moved by calls to the [moveTo]
  // method.
  @override
  double get velocity => 0.0;

  void moveTo(double newPixels) {
    _updateUserScrollDirection();
    delegate.setPixelsInternal(newPixels);
  }

  void jumpTo(double newPixels) {
    _updateUserScrollDirection();
    delegate.forcePixelsInternal(newPixels);
  }

  void _updateUserScrollDirection() {
    assert(drivers.isNotEmpty);
    ScrollDirection commonDirection;
    for (_LinkedScrollPosition driver in drivers) {
      commonDirection ??= driver.userScrollDirection;
      if (driver.userScrollDirection != commonDirection) {
        commonDirection = ScrollDirection.idle;
      }
    }
    delegate.updateUserScrollDirection(commonDirection);
  }

  @override
  void dispose() {
    for (_LinkedScrollPosition driver in drivers) {
      driver.unlink(this);
    }
    super.dispose();
  }
}
