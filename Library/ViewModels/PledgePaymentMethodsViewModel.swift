import KsApi
import PassKit
import Prelude
import ReactiveSwift
import UIKit

public typealias PledgePaymentMethodsValue = (user: User, project: Project, applePayCapable: Bool)

public protocol PledgePaymentMethodsViewModelInputs {
  func applePayButtonTapped()
  func configureWith(_ value: PledgePaymentMethodsValue)
  func creditCardSelected(paymentSourceId: String)
  func addNewCardViewControllerDidAdd(newCard card: GraphUserCreditCard.CreditCard)
  func viewDidLoad()
  func addNewCardTapped(with intent: AddNewCardIntent)
}

public protocol PledgePaymentMethodsViewModelOutputs {
  var applePayButtonHidden: Signal<Bool, Never> { get }
  var goToAddCardScreen: Signal<(AddNewCardIntent, Project), Never> { get }
  var notifyDelegateApplePayButtonTapped: Signal<Void, Never> { get }
  var notifyDelegateCreditCardSelected: Signal<String, Never> { get }
  var notifyDelegateLoadPaymentMethodsError: Signal<String, Never> { get }
  var reloadPaymentMethodsAndSelectCard:
    Signal<([PledgeCreditCardViewData], GraphUserCreditCard.CreditCard?), Never> { get }
  var updateSelectedCreditCard: Signal<GraphUserCreditCard.CreditCard, Never> { get }
}

public protocol PledgePaymentMethodsViewModelType {
  var inputs: PledgePaymentMethodsViewModelInputs { get }
  var outputs: PledgePaymentMethodsViewModelOutputs { get }
}

public final class PledgePaymentMethodsViewModel: PledgePaymentMethodsViewModelType,
  PledgePaymentMethodsViewModelInputs, PledgePaymentMethodsViewModelOutputs {
  public init() {
    let configureWithValue = Signal.combineLatest(
      self.viewDidLoadProperty.signal,
      self.configureWithValueProperty.signal.skipNil()
    )
    .map(second)

    let project = configureWithValue.map { $0.project }

    let availableCardTypes = project.map { $0.availableCardTypes }.skipNil()

    let storedCardsEvent = configureWithValue
      .switchMap { _ in
        AppEnvironment.current.apiService
          .fetchGraphCreditCards(query: UserQueries.storedCards.query)
          .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
          .materialize()
      }

    self.applePayButtonHidden = configureWithValue
      .map { ($0.project, $0.applePayCapable) }
      .map(showApplePayButton(for:applePayCapable:))
      .negate()

    let storedCardsValues = storedCardsEvent.values().map { $0.me.storedCards.nodes }
    let backing = configureWithValue.map { $0.project.personalization.backing }

    let storedCards = Signal.combineLatest(storedCardsValues, backing)
      .map(cards(_:orderedBy:))

    let newCard = Signal.merge(
      configureWithValue.mapConst(nil),
      self.newCreditCardProperty.signal
    )

    self.reloadPaymentMethodsAndSelectCard = Signal.combineLatest(
      storedCards,
      newCard,
      availableCardTypes,
      project
    )
    .map(pledgeCreditCardViewDataAndSelectedCard)

    self.notifyDelegateApplePayButtonTapped = self.applePayButtonTappedProperty.signal

    self.notifyDelegateLoadPaymentMethodsError = storedCardsEvent
      .errors()
      .map { $0.localizedDescription }

    self.notifyDelegateCreditCardSelected = self.creditCardSelectedSignal
      .skipRepeats()

    self.updateSelectedCreditCard = storedCards
      .takePairWhen(self.creditCardSelectedSignal)
      .map { cards, id in cards.filter { $0.id == id }.first }
      .skipNil()

    self.goToAddCardScreen = Signal.combineLatest(self.addNewCardIntentProperty.signal.skipNil(), project)

    // Tracking

    project
      .filter { isCreatingPledge($0) }
      .takeWhen(self.goToAddCardScreen)
      .observeValues {
        AppEnvironment.current.koala.trackAddNewCardButtonClicked(
          project: $0
        )
      }
  }

  private let applePayButtonTappedProperty = MutableProperty(())
  public func applePayButtonTapped() {
    self.applePayButtonTappedProperty.value = ()
  }

  private let configureWithValueProperty = MutableProperty<PledgePaymentMethodsValue?>(nil)
  public func configureWith(_ value: PledgePaymentMethodsValue) {
    self.configureWithValueProperty.value = value
  }

  private let (creditCardSelectedSignal, creditCardSelectedObserver) = Signal<String, Never>.pipe()
  public func creditCardSelected(paymentSourceId: String) {
    self.creditCardSelectedObserver.send(value: paymentSourceId)
  }

  private let newCreditCardProperty = MutableProperty<GraphUserCreditCard.CreditCard?>(nil)
  public func addNewCardViewControllerDidAdd(newCard card: GraphUserCreditCard.CreditCard) {
    self.newCreditCardProperty.value = card
  }

  private let addNewCardIntentProperty = MutableProperty<AddNewCardIntent?>(nil)
  public func addNewCardTapped(with intent: AddNewCardIntent) {
    self.addNewCardIntentProperty.value = intent
  }

  private let viewDidLoadProperty = MutableProperty(())
  public func viewDidLoad() {
    self.viewDidLoadProperty.value = ()
  }

  public let applePayButtonHidden: Signal<Bool, Never>
  public let goToAddCardScreen: Signal<(AddNewCardIntent, Project), Never>
  public let notifyDelegateApplePayButtonTapped: Signal<Void, Never>
  public let notifyDelegateCreditCardSelected: Signal<String, Never>
  public let notifyDelegateLoadPaymentMethodsError: Signal<String, Never>
  public let reloadPaymentMethodsAndSelectCard:
    Signal<([PledgeCreditCardViewData], GraphUserCreditCard.CreditCard?), Never>

  public let updateSelectedCreditCard: Signal<GraphUserCreditCard.CreditCard, Never>

  public var inputs: PledgePaymentMethodsViewModelInputs { return self }
  public var outputs: PledgePaymentMethodsViewModelOutputs { return self }
}

private func pledgeCreditCardViewDataAndSelectedCard(
  with cards: [GraphUserCreditCard.CreditCard],
  newAddedCard: GraphUserCreditCard.CreditCard?,
  availableCardTypes: [String],
  project: Project
) -> ([PledgeCreditCardViewData], GraphUserCreditCard.CreditCard?) {
  let allCards = ([newAddedCard] + cards).compact()

  let data = allCards.compactMap { card -> PledgeCreditCardViewData? in
    guard let cardBrand = card.type?.rawValue else { return nil }

    let isAvailableCardType = availableCardTypes.contains(cardBrand)

    return (card, isAvailableCardType, project.location.displayableName)
  }

  // If there is no backing, simply select the first card in the list.
  guard let backing = project.personalization.backing else {
    return (data, allCards.first)
  }

  // If we're working with a backing, but we have a newly added card, select the newly added card.
  if let newCard = newAddedCard {
    return (data, newCard)
  }

  /*
   If we're working with a backing, and a new card hasn't been added,
   select the card that the backing is associated with.
   */
  let backedCard = allCards.first(where: { $0.id == backing.paymentSource?.id })

  return (data, backedCard)
}

private func showApplePayButton(for project: Project, applePayCapable: Bool) -> Bool {
  return applePayCapable &&
    AppEnvironment.current.config?.applePayCountries.contains(project.country.countryCode) ?? false
}

private func isCreatingPledge(_ project: Project) -> Bool {
  guard let isBacking = project.personalization.isBacking else { return true }

  return !isBacking
}

private func cards(
  _ cards: [GraphUserCreditCard.CreditCard],
  orderedBy backing: Backing?
) -> [GraphUserCreditCard.CreditCard] {
  return cards.sorted { card1, _ in card1.id == backing?.paymentSource?.id }
}
