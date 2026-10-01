import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';

class SearchState extends Equatable {
  const SearchState({
    this.query = '',
    this.results = const [],
    this.loading = false,
    this.error,
    this.recentResults = const [],
    this.city,
    this.cityOptions = const [],
  });

  final String query;
  final List<SearchResult> results;
  final bool loading;
  final AppError? error;
  final List<SearchResult> recentResults;

  /// TDX code of the city the results are filtered to, or null for every
  /// city. Null is the resting state — there is no "all cities" option to
  /// pick, only nothing picked.
  final String? city;

  final List<String> cityOptions;

  SearchState copyWith({
    String? query,
    List<SearchResult>? results,
    bool? loading,
    AppError? error,
    bool clearError = false,
    List<SearchResult>? recentResults,
    String? city,
    bool clearCity = false,
    List<String>? cityOptions,
  }) => SearchState(
    query: query ?? this.query,
    results: results ?? this.results,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    recentResults: recentResults ?? this.recentResults,
    city: clearCity ? null : (city ?? this.city),
    cityOptions: cityOptions ?? this.cityOptions,
  );

  @override
  List<Object?> get props => [
    query,
    results,
    loading,
    error,
    recentResults,
    city,
    cityOptions,
  ];
}
